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

- MinIO: uma release de jan/2023, por exemplo `quay.io/minio/minio:RELEASE.2023-01-31T02-24-19Z` (confira se a tag existe no quay.io).
- Redis: `redis:7.0`.

Faça a troca nas cópias dos manifestos, não nos originais. Use o `mc` (cliente) de data próxima à do servidor.

### 1. Namespace com injeção do sidecar

`todas$`

```bash
kubectl create ns control-engine
kubectl label ns control-engine istio-injection=enabled
```

### 2. MinIO

`fog1$` (equivalente no fog2 e no cloud1, trocando o sufixo):

```bash
cd ~/MicroFog/Prototype_Setup/minio-setup
N=control-engine
kubectl -n $N apply -f minio_fog1.yaml                 # o servidor deste cluster
kubectl -n $N apply -f minioService.yaml               # Service "minio" (dados, todos os clusters)
kubectl -n $N apply -f minio_vs.yaml -f minio_dr.yaml  # roteamento + failover por localidade
# Services de gerenciamento de TODOS os clusters, para a replicação:
kubectl -n $N apply -f minioManagementService_fog1.yaml \
                    -f minioManagementService_fog2.yaml \
                    -f minioManagementService_cloud1.yaml
```

**Desvio do guia original:** não aplicamos `minioGW.yaml` nem `minioVS_*.yaml`, que expõem o console do MinIO na porta 80 do ingress. Essa porta também é usada pelos gateways do CE e das aplicações (hosts `"*"`), e as rotas podem entrar em conflito. Em vez disso, acesse o console por `kubectl port-forward`:

```bash
fog1$ kubectl -n control-engine port-forward svc/minio-fog1 9000:9000 9090:9090
```

### 3. Bucket, versionamento e replicação

`fog1$` (em outro terminal, com o port-forward ativo; repita o port-forward no fog2 e no cloud1 para os comandos `mc` correspondentes):

```bash
mc alias set fog1 http://localhost:9000 minioadmin minioadmin
mc mb fog1/microfog-app-metadata
mc version enable fog1/microfog-app-metadata
```

Faça o mesmo no fog2 e no cloud1. A replicação **ativa-ativa** entre os três é configurada servidor a servidor. Os endereços são os nomes internos dos Services de gerenciamento, que cada servidor alcança pela malha:

```bash
# no fog1, replicar para fog2 e cloud1
mc replicate add fog1/microfog-app-metadata \
  --remote-bucket http://minioadmin:minioadmin@minio-fog2.control-engine.svc.cluster.local:9000/microfog-app-metadata \
  --replicate "delete,delete-marker,existing-objects"
mc replicate add fog1/microfog-app-metadata \
  --remote-bucket http://minioadmin:minioadmin@minio-cloud1.control-engine.svc.cluster.local:9000/microfog-app-metadata \
  --replicate "delete,delete-marker,existing-objects"
```

Repita no fog2 (para fog1 e cloud1) e no cloud1 (para fog1 e fog2). A sintaxe de `mc replicate add` mudou entre versões. Se a sua versão não aceitar `--remote-bucket` com URL, consulte `mc replicate add --help`. Referência: <https://min.io/docs/minio/linux/administration/bucket-replication/enable-server-side-two-way-bucket-replication.html>

### 4. Upload dos YAMLs das aplicações

A pasta precisa ter **o mesmo nome do `applicationId`** usado nos metadados (`hcApp`, `app2`). Antes do upload, ajuste as imagens conforme `IMAGE_SOURCE` ([M0](m0-build.md#origem-das-imagens-image_source)): é aqui que o script `set-images.sh` deve ser escrito e testado.

```bash
fog1$ WG=~/MicroFog/Workload_Generator/sample-deployment-resources
fog1$ mkdir -p ~/upload && cp -r $WG/hcApp $WG/app2 ~/upload/
fog1$ # reescrever image: e imagePullPolicy em ~/upload/*/*.yaml (set-images.sh)
fog1$ mc cp --recursive ~/upload/hcApp/ fog1/microfog-app-metadata/hcApp/
fog1$ mc cp --recursive ~/upload/app2/  fog1/microfog-app-metadata/app2/
```

Confira a replicação:

```bash
fog2$ mc ls fog2/microfog-app-metadata/hcApp/
```

### 5. Redis

```bash
cd ~/MicroFog/Prototype_Setup/redis-setup
cloud1$ kubectl -n control-engine apply -f redis-primary.yaml
fog1$   kubectl -n control-engine apply -f redis-replica.yaml
fog2$   kubectl -n control-engine apply -f redis-replica.yaml
todas$  kubectl -n control-engine apply -f redis-service.yaml -f redis-service-primary.yaml \
                                         -f redis-vs.yaml -f redis-dr.yaml
```

As réplicas apontam para `redis-primary.control-engine.svc.cluster.local` (`--slaveof`), que só tem endpoint no cloud1. A replicação Redis passa pela malha.

```bash
fog1$ kubectl -n control-engine exec redis-replica -c redis-replica -- redis-cli info replication
```

Esperado: `role:slave` e `master_link_status:up`. (Confira o nome real do pod e do container com `kubectl get pods`.)

Os metadados só serão gravados no M4, quando o CE do cloud1 subir.

## O que observar

- `mc ls` mostra os mesmos arquivos nos três servidores, embora o upload tenha sido feito em um só.
- `kubectl -n control-engine get endpoints minio -o wide` mostra só o endpoint local. Os remotos são vistos pelo Istio:

  ```bash
  istioctl proxy-config endpoints deploy/sleep.sample \
    --cluster "outbound|9000||minio.control-engine.svc.cluster.local"
  ```

## Verifique seu entendimento

1. Por que o CE acessa `minio.control-engine...` e não `minio-fog1.control-engine...`? O que se perderia?
2. Apague um arquivo no cloud1 (`mc rm`). Ele some nos fogs? Qual opção do `mc replicate add` controla isso?
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
