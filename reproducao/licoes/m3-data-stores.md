# M3 — Data stores (MinIO e Redis)

## Objetivo

Nos três clusters, no namespace `control-engine`:
- **MinIO YAML Store**: um servidor por cluster, com o bucket `microfog-app-metadata` **replicado** entre os três e contendo os YAMLs do hcApp e do app2.
- **Redis Meta Data Store**: primário no cloud1 e réplicas no fog1 e no fog2.

## Conceitos

### Por que dois data stores (§3.3.2)

| Store | Guarda | Quem escreve | Quem lê |
|---|---|---|---|
| **MinIO** (armazenamento de objetos, compatível com S3) | Os **YAMLs** Kubernetes/Istio de cada microserviço (Pod, Service, VS, DR, ConfigMap...), numa pasta por aplicação | Você (upload) | O CE, na hora do deploy (eventos `LOAD_YAML_FILE_BEGIN/COMPLETED` no log) |
| **Redis** (chave-valor em memória) | Os **metadados** das aplicações: microserviços, requisitos, dataflows, serviços compostos (o modelo da Fig. 5) | O CE do cloud1 na inicialização (`controlengine.populatemetadata = true`), a partir das classes em `metadata/` | Os CEs, ao processar um PR (`RETRIEVE_REDIS_DATA_BEGIN/END`) |

### Arquitetura distribuída (§4.1, §4.2, Fig. 6)

Cada CE acessa os stores pelo **mesmo nome DNS** (`minio.control-engine.svc.cluster.local`, `redis.control-engine.svc.cluster.local`). Esse Service existe em todos os clusters e, graças à malha do M2, tem endpoints **em todos os clusters**. Quem escolhe *qual* instância atende é a **DestinationRule** com `localityLbSetting`:

```yaml
# Prototype_Setup/minio-setup/minio_dr.yaml (resumo)
trafficPolicy:
  loadBalancer:
    localityLbSetting:
      enabled: true
      failover:
        - from: fog
          to: cloud
  outlierDetection:          # sem isso o failover por localidade não é ativado
    consecutive5xxErrors: 1
    interval: 1s
```

Na prática: primeiro a instância da **mesma zona** (o próprio cluster); se ela falhar, outra da **mesma região** (o outro fog); só depois a **cloud**. É o comportamento medido na Fig. 11 e que vamos provocar no M9.

O MinIO tem também uma camada de **gerenciamento**: Services `minio-fog1`, `minio-fog2` e `minio-cloud1`, cada um selecionando **uma** instância específica (`clustername: fog1`). Eles são aplicados em todos os clusters, para que um servidor MinIO alcance os outros pelo nome e possa **replicar** o bucket.

## Passos

### 0. Fixar as versões das imagens

Os manifestos usam `quay.io/minio/minio:latest` e `redis` (sem tag). Em 2026, `latest` traz versões muito diferentes das de 2022. A edição comunitária do MinIO mudou bastante em 2025, inclusive o console. Fixe versões da época:

- MinIO: uma release de jan/2023, `quay.io/minio/minio:RELEASE.2023-01-31T02-24-19Z`.
- Redis: `redis:7.0`.

O `mc` (cliente) da mesma época foi instalado no [00](00-preparar-pcs-e-rede.md), passo 8.

`clusters$` (pc-lamp-1 a 3) faça a troca em cópias dos manifestos, em `~/stores/`, e não nos originais. Assim o `git status` do clone continua limpo, e os originais servem de referência:

```bash
mkdir -p ~/stores
cp -r ~/MicroFog/Prototype_Setup/minio-setup ~/MicroFog/Prototype_Setup/redis-setup ~/stores/
sed -i 's#quay.io/minio/minio:latest#quay.io/minio/minio:RELEASE.2023-01-31T02-24-19Z#' ~/stores/minio-setup/minio_*.yaml
sed -i -E 's#^(\s*image:\s*)redis\s*$#\1redis:7.0#' ~/stores/redis-setup/redis-*.yaml
grep -rn "image:" ~/stores      # nenhuma linha com :latest ou "redis" sem tag
```

Confira se as tags ainda existem. O projeto open source do MinIO foi arquivado, e imagens antigas podem sumir dos registries:

```bash
docker pull quay.io/minio/minio:RELEASE.2023-01-31T02-24-19Z
docker pull redis:7.0
```

### 1. Namespace com injeção do sidecar

O sidecar é o que põe os stores na malha: sem ele, o failover por localidade e a replicação entre clusters não funcionam.

`clusters$` (pc-lamp-1 a 3) crie o namespace com injeção de sidecar:

```bash
kubectl create ns control-engine
kubectl label ns control-engine istio-injection=enabled
```

### 2. MinIO

`clusters$` (pc-lamp-1 a 3), trocando `C` conforme o PC (`fog1`, `fog2` ou `cloud1`):

```bash
C=fog1
cd ~/stores/minio-setup
N=control-engine
kubectl -n $N apply -f minio_$C.yaml                   # o servidor deste cluster
kubectl -n $N apply -f minioService.yaml               # Service "minio" (dados, todos os clusters)
kubectl -n $N apply -f minio_vs.yaml -f minio_dr.yaml  # roteamento + failover por localidade
# Services de gerenciamento de TODOS os clusters, para a replicação:
kubectl -n $N apply -f minioManagementService_fog1.yaml \
                    -f minioManagementService_fog2.yaml \
                    -f minioManagementService_cloud1.yaml
kubectl -n $N wait --for=condition=Ready pod/minio-$C --timeout=300s
```

**Desvio do guia original:** não aplicamos `minioGW.yaml` nem `minioVS_*.yaml`, que expõem o console do MinIO na porta 80 do ingress. Essa porta também é usada pelos gateways do CE e das aplicações (hosts `"*"`), e as rotas podem entrar em conflito. Em vez disso, acesse o MinIO por `kubectl port-forward`, que liga uma porta do PC ao Service dentro do cluster.

`clusters$` (pc-lamp-1 a 3) num **terminal separado**, que fica ocupado enquanto o port-forward estiver ativo (`Ctrl+C` encerra):

```bash
C=fog1
kubectl -n control-engine port-forward svc/minio-$C 9000:9000 9090:9090
```

A API S3 fica em `localhost:9000`, usada pelo `mc`. O console web fica em `localhost:9090` do PC do cluster. Para vê-lo de um computador com navegador ligado ao switch, abra um túnel SSH (troque o usuário e o IP) e acesse `http://localhost:9090`:

```bash
ssh -L 9090:localhost:9090 <usuário>@192.168.0.11
```

### 3. Bucket, versionamento e replicação

A replicação só funciona entre buckets que já existem e têm versionamento. Por isso, crie o bucket **nos três clusters** antes de configurar a replicação em qualquer um.

`clusters$` (pc-lamp-1 a 3) no terminal principal, com o port-forward ativo no outro:

```bash
C=fog1
mc alias set $C http://localhost:9000 minioadmin minioadmin
mc mb $C/microfog-app-metadata
mc version enable $C/microfog-app-metadata
mc version info $C/microfog-app-metadata     # "versioning is enabled"
```

A replicação **ativa-ativa** entre os três é configurada servidor a servidor: cada um replica para os outros dois. Os endereços são os nomes internos dos Services de gerenciamento, que cada servidor alcança pela malha.

`clusters$` (pc-lamp-1 a 3) depois que os três buckets existirem (o laço pula o próprio cluster):

```bash
C=fog1
for r in fog1 fog2 cloud1; do
  [ "$r" = "$C" ] && continue
  mc replicate add $C/microfog-app-metadata \
    --remote-bucket http://minioadmin:minioadmin@minio-$r.control-engine.svc.cluster.local:9000/microfog-app-metadata \
    --replicate "delete,delete-marker,existing-objects"
done
mc replicate ls $C/microfog-app-metadata      # duas regras
```

A sintaxe de `mc replicate add` mudou entre versões; a de cima é a do `mc` de jan/2023 instalado no 00. Se a sua versão não aceitar `--remote-bucket` com URL, consulte `mc replicate add --help`.

### 4. Upload dos YAMLs das aplicações

A pasta precisa ter **o mesmo nome do `applicationId`** usado nos metadados (`hcApp`, `app2`). Antes do upload, ajuste as imagens conforme `IMAGE_SOURCE` ([M0](m0-build.md#origem-das-imagens-image_source)).

O script `set-images.sh` faz essa troca. Ele lê a tag da imagem original (`samodha/dummy-microservice-test:hcm1` → `hcm1`; `samodha/microfog:latest` → CE), troca a linha `image:` pela referência por digest da origem escolhida e põe `imagePullPolicy: IfNotPresent`. Assim, uma republicação da tag não muda a imagem no meio dos experimentos, e os nós não baixam a imagem de novo a cada pod (D15). O mesmo script é usado no M4, nos manifestos do CE.

`carga$` (pc-lamp-5) grave o script. Antes, troque cada `PREENCHER` das linhas `local_` pela referência completa anotada no M0, passo 5 (`ghcr.io/<org>/...@sha256:...`). Se o build do M0 falhou, deixe-as como estão e use `upstream`:

```bash
cat > ~/set-images.sh <<'SCRIPT'
#!/usr/bin/env bash
# Uso: set-images.sh <upstream|local> <arquivo.yaml>...
set -euo pipefail
src=$1; shift

declare -A upstream=(
  [ce]=samodha/microfog@sha256:b6342ae19edfd854d3102564cc6e7da65369c45cebbf459f900811607adb93c2
  [hcm1]=samodha/dummy-microservice-test@sha256:ab602dab1e525d2df7d4a1e2a13bd65abc35082f50edd938e419edb1d2977a36
  [hcm2]=samodha/dummy-microservice-test@sha256:d81db14c03cae3ffbf3c01dfbd75f7d3cf5dca9c4cb99c6022adf41dddd8389b
  [hcm3]=samodha/dummy-microservice-test@sha256:071e1c1d50a62bf2d2b1e5b0ae2eec8dd6ae62513765ac38c80ac56c47904a6e
  [a2m1]=samodha/dummy-microservice-test@sha256:b7f74d3dfe4901adf1617875da29e9862bfcfa26b6ced43dc2e8c7a42014497a
  [a2m2]=samodha/dummy-microservice-test@sha256:fac0e64e3c067341d764153fbe797de2892ff6c3742cc778489e733b90730ecf
  [a2m3]=samodha/dummy-microservice-test@sha256:0a7c1c205828cb1c6151a9ea118c76ba7f3b96250966e131e05827c4954e8af5
  [a2m4]=samodha/dummy-microservice-test@sha256:d96418b90992cf69c1c2ebb037543ea3c7e42a06557f2e9574d8fbad2850f47a
)
declare -A local_=(
  [ce]=PREENCHER
  [hcm1]=PREENCHER
  [hcm2]=PREENCHER
  [hcm3]=PREENCHER
  [a2m1]=PREENCHER
  [a2m2]=PREENCHER
  [a2m3]=PREENCHER
  [a2m4]=PREENCHER
)

for f in "$@"; do
  img=$(sed -nE 's/^\s*image:\s*(\S+)\s*$/\1/p' "$f")
  [ -z "$img" ] && continue
  case $img in
    samodha/microfog:*)                key=ce ;;
    samodha/dummy-microservice-test:*) key=${img##*:} ;;
    *) echo "ignorado (não é uma imagem original): $f $img"; continue ;;
  esac
  case $src in
    upstream) ref=${upstream[$key]} ;;
    local)    ref=${local_[$key]} ;;
    *) echo "origem inválida: $src"; exit 1 ;;
  esac
  if [[ $ref == *PREENCHER* ]]; then echo "digest local de $key não preenchido"; exit 1; fi
  sed -i -E "s#^(\s*image:\s*).*#\1$ref#; s#^(\s*imagePullPolicy:\s*).*#\1IfNotPresent#" "$f"
  echo "$f -> $ref"
done
SCRIPT
chmod +x ~/set-images.sh
for h in fog1 fog2 cloud1 fog3; do scp ~/set-images.sh $h:; done
```

`fog1$` (pc-lamp-1) copie os YAMLs, troque as imagens e envie ao MinIO. `IMAGE_SOURCE=local` é o padrão (D15); use `upstream` para as imagens dos autores:

```bash
IMAGE_SOURCE=local
WG=~/MicroFog/Workload_Generator/sample-deployment-resources
rm -rf ~/upload && mkdir -p ~/upload && cp -r $WG/hcApp $WG/app2 ~/upload/
~/set-images.sh $IMAGE_SOURCE ~/upload/*/*.yaml
grep -rn -E "image:|imagePullPolicy" ~/upload       # digests e IfNotPresent em todos
mc cp --recursive ~/upload/hcApp/ fog1/microfog-app-metadata/hcApp/
mc cp --recursive ~/upload/app2/  fog1/microfog-app-metadata/app2/
```

Confira a replicação no fog2 e no cloud1, com o port-forward deles ativo.

`fog2$` (pc-lamp-2):

```bash
mc ls fog2/microfog-app-metadata/hcApp/
```

`cloud1$` (pc-lamp-3):

```bash
mc ls cloud1/microfog-app-metadata/hcApp/
```

### 5. Redis

Os manifestos usados são as cópias de `~/stores/`, com `redis:7.0` (passo 0).

`cloud1$` (pc-lamp-3) suba o primário:

```bash
cd ~/stores/redis-setup && kubectl -n control-engine apply -f redis-primary.yaml
```

`fog1$` (pc-lamp-1) e `fog2$` (pc-lamp-2) subam as réplicas:

```bash
cd ~/stores/redis-setup && kubectl -n control-engine apply -f redis-replica.yaml
```

`clusters$` (pc-lamp-1 a 3) crie os Services, o VS e a DR:

```bash
cd ~/stores/redis-setup && kubectl -n control-engine apply \
  -f redis-service.yaml -f redis-service-primary.yaml -f redis-vs.yaml -f redis-dr.yaml
```

As réplicas apontam para `redis-primary.control-engine.svc.cluster.local` (`--slaveof`), que só tem endpoint no cloud1. A replicação Redis passa pela malha.

`fog1$` (pc-lamp-1) confira a réplica:

```bash
kubectl -n control-engine exec redis-replica -c redis-replica -- redis-cli info replication
```

Esperado: `role:slave` e `master_link_status:up`. `fog2$` (pc-lamp-2) confira também:

```bash
kubectl -n control-engine exec redis-replica -c redis-replica -- redis-cli info replication
```

Os metadados só serão gravados no M4, quando o CE do cloud1 subir.

## O que observar

- `mc ls` mostra os mesmos arquivos nos três servidores, embora o upload tenha sido feito em um só.
- `kubectl -n control-engine get endpoints minio -o wide` mostra só o endpoint local. Os remotos são vistos pelo Istio, pelo sidecar do `sleep` do M2. `fog1$` (pc-lamp-1):

  ```bash
  istioctl proxy-config endpoints deploy/sleep.sample \
    --cluster "outbound|9000||minio.control-engine.svc.cluster.local"
  ```

## Verifique seu entendimento

1. Por que o CE acessa `minio.control-engine...` e não `minio-fog1.control-engine...`? O que se perderia?
2. Apague um arquivo no cloud1 (`cloud1$ mc rm cloud1/microfog-app-metadata/hcApp/hcm1-config.yaml`) e liste o bucket no fog1 (`fog1$ mc ls fog1/microfog-app-metadata/hcApp/`). Ele some nos fogs? Envie o arquivo de volta depois (`fog1$ mc cp ~/upload/hcApp/hcm1-config.yaml fog1/microfog-app-metadata/hcApp/`). Qual opção do `mc replicate add` controla isso?
3. Com as réplicas Redis somente leitura nos fogs, o que aconteceria se um CE do fog tentasse **escrever** no Redis? *(Observe os logs no M4/M5.)*
4. Na Fig. 6, onde ficam as duas camadas (gerenciamento e acesso a dados)? Associe cada arquivo do `minio-setup/` a uma delas.

## Problemas comuns

| Sintoma | Causa provável | Diagnóstico |
|---|---|---|
| `mc replicate add` → "remote target not reachable" | O Service de gerenciamento do outro cluster não foi aplicado aqui, ou a malha não funciona | `kubectl -n control-engine get svc`; volte ao M2 |
| Replicação exige versionamento | Bucket sem `mc version enable` em algum lado | `mc version info` |
| Réplica Redis com `master_link_status:down` | `redis-primary` sem endpoint remoto | `istioctl proxy-config endpoints` para a 6379 |
| Pod MinIO sem iniciar por volume | `hostPath` inexistente no nó KinD | `kubectl describe pod`; o caminho é criado dentro do container do nó |

## Registro de execução

- Data:
- Versões de MinIO, `mc` e Redis:
- Sintaxe de replicação que funcionou:
- Desvios do plano:
