# M2 — Malha Istio multi-cluster

## Objetivo

Os três clusters formam **uma única malha de serviços** (Istio *multi-primary, multi-network*). A prova: um pod no fog1 chama `helloworld.sample:5000` e recebe respostas de pods que estão no fog2 e no cloud1.

Esta é a parte mais frágil de toda a reprodução. Faça com calma, com a configuração do M1 já guardada no `carga`.

## Conceitos

### Service mesh (§2.3.3)

O Istio injeta um **sidecar** (proxy Envoy) em cada pod. Todo o tráfego do pod passa por esse proxy, que pode então rotear, balancear, aplicar mTLS e coletar métricas sem mudar a aplicação. Dois recursos do Istio aparecem o tempo todo no MicroFog:

- **VirtualService (VS)**: *para onde* vai uma requisição (regras de rota, por exemplo por cabeçalho HTTP).
- **DestinationRule (DR)**: *como* chegar lá (subconjuntos de pods, pesos, failover, outlier detection).

O CE do MicroFog **gera e aplica VS e DR** para compor os microserviços entre clusters (M6/M7).

### Multi-primary, multi-network (§2.3.5)

- **Multi-primary**: cada cluster tem o seu próprio plano de controle (`istiod`). Se o cloud1 cair, os fogs continuam funcionando, o que é desejável em fog computing.
- **Multi-network**: os pods de clusters diferentes **não** se alcançam diretamente por IP. O tráfego entre clusters passa por um **east-west gateway** em cada cluster (porta 15443), com TLS *passthrough*.
- Para um cluster saber quais pods existem nos outros, o `istiod` de cada um **lê o API server dos outros**, por meio de *remote secrets* (kubeconfigs).
- Para os sidecars confiarem uns nos outros (mTLS), os três clusters precisam de **certificados assinados pela mesma CA raiz**.

```
 fog1                               fog2
 ┌──────────────────────┐          ┌──────────────────────┐
 │ sleep ─► sidecar ─────┼─15443──►│ east-west gw ─► hello │
 │ istiod ──lê API──────┼──6443──►│ API server            │
 └──────────────────────┘          └──────────────────────┘
        (o mesmo para cloud1)
```

Os arquivos do repositório usados aqui (`Prototype_Setup/cluster-setup/`):

| Arquivo | Função |
|---|---|
| `<cluster>/istio-<cluster>.yaml` | `IstioOperator`: nome do cluster, rede, east-west gateway (com `loadBalancerIP` = IP do PC) e ingress gateway |
| `istio-cross-gateway.yaml` | Abre a 15443 do east-west para os serviços `*.local` |
| `apiserver-gateway.yaml` + `apiserver-vs.yaml` | Expõem o API server na porta 6443 do east-west, para os remote secrets |

## Passos

Versão do Istio: a definida no portão do [M1](m1-clusters.md#portão-gono-go-de-versões). Abaixo, `$ISTIO` é o diretório extraído (ex.: `~/istio-1.16.7`), gravado no `~/.bashrc` no M1. Confira antes de começar:

```bash
echo $ISTIO && ls $ISTIO/bin/istioctl
```

### 1. CA raiz comum

`fog1$` (pc-lamp-1) gere uma CA raiz e um certificado intermediário por cluster. Isso só é feito no fog1.

Os certificados são gerados por um Makefile que vem com o Istio. O Ubuntu Server não traz o `make`, então instale-o antes:

```bash
sudo apt install -y make
mkdir -p ~/certs && cd ~/certs
make -f $ISTIO/tools/certs/Makefile.selfsigned.mk root-ca
for c in fog1 fog2 cloud1; do make -f $ISTIO/tools/certs/Makefile.selfsigned.mk $c-cacerts; done
scp -r ~/certs/fog2   fog2:~/certs-fog2
scp -r ~/certs/cloud1 cloud1:~/certs-cloud1
```

`clusters$` (pc-lamp-1 a 3) crie o secret `cacerts` **antes** de instalar o Istio. Troque `D` conforme o PC: `~/certs/fog1` no fog1, `~/certs-fog2` no fog2, `~/certs-cloud1` no cloud1:

```bash
D=~/certs/fog1
ls $D      # ca-cert.pem  ca-key.pem  cert-chain.pem  root-cert.pem

kubectl create namespace istio-system
kubectl -n istio-system create secret generic cacerts \
  --from-file=$D/ca-cert.pem --from-file=$D/ca-key.pem \
  --from-file=$D/root-cert.pem --from-file=$D/cert-chain.pem
```

### 2. Rede do namespace e instalação

`clusters$` (pc-lamp-1 a 3) troque as três variáveis conforme o PC, com as redes dos arquivos do repositório:

| PC | `C` | `NET` | `IP` |
|---|---|---|---|
| fog1 | `fog1` | `network1` | `192.168.0.11` |
| fog2 | `fog2` | `network2` | `192.168.0.12` |
| cloud1 | `cloud1` | `network3` | `192.168.0.13` |

```bash
C=fog1
NET=network1
IP=192.168.0.11

kubectl label namespace istio-system topology.istio.io/network=$NET

sed "s/<PUBLIC_IP_OF_THE_VM>/$IP/" \
  ~/MicroFog/Prototype_Setup/cluster-setup/$C/istio-$C.yaml > ~/clusters/istio-$C.yaml

$ISTIO/bin/istioctl install -y -f ~/clusters/istio-$C.yaml \
  --set components.pilot.k8s.resources.requests.cpu=100m \
  --set components.pilot.k8s.resources.requests.memory=512Mi
```

Por que reduzir os *requests* do `istiod`: o padrão (500m / 2 GiB) pesa nos nós lógicos pequenos do M1 (1,5 vCPU / 3 GB), e o que o Istio reserva **some do allocatable que o CE enxerga** para as aplicações.

```bash
kubectl -n istio-system get pods,svc -o wide
```

O Service `istio-eastwestgateway` deve ter `EXTERNAL-IP` = IP do PC (vindo do MetalLB).

### 3. Gateways entre clusters

`clusters$` (pc-lamp-1 a 3) crie os gateways:

```bash
cd ~/MicroFog/Prototype_Setup/cluster-setup
kubectl -n istio-system apply -f istio-cross-gateway.yaml
kubectl -n istio-system apply -f apiserver-gateway.yaml -f apiserver-vs.yaml
```

`fog2$` (pc-lamp-2) teste a partir de **outro** PC: o API server do fog1 deve responder através do gateway, com certificado válido para o IP (M1, passo 2):

```bash
curl -k https://192.168.0.11:6443/version
```

### 4. `meshNetworks`

`clusters$` (pc-lamp-1 a 3) diga a cada `istiod` onde fica o gateway de cada rede. A lista fica na chave `meshNetworks` do ConfigMap `istio`, ao lado (e não dentro) da chave `mesh`, como no guia original (`Prototype_Setup/docs/cluster_setup.pdf`). O comando é o mesmo nos três PCs:

```bash
kubectl -n istio-system patch configmap istio --type merge -p '
data:
  meshNetworks: |-
    networks:
      network1:
        endpoints: [{fromRegistry: kind-fog1}]
        gateways: [{address: 192.168.0.11, port: 15443}]
      network2:
        endpoints: [{fromRegistry: kind-fog2}]
        gateways: [{address: 192.168.0.12, port: 15443}]
      network3:
        endpoints: [{fromRegistry: kind-cloud1}]
        gateways: [{address: 192.168.0.13, port: 15443}]
'
kubectl -n istio-system get configmap istio -o jsonpath='{.data.meshNetworks}'
```

`kind-fog1` etc. são os `clusterName` definidos nos arquivos `istio-*.yaml`. O `istiod` relê o ConfigMap sozinho; confira no log:

```bash
kubectl -n istio-system logs deploy/istiod --since=2m | grep -i meshnetworks
```

### 5. Remote secrets

Cada cluster precisa de um secret de cada um dos outros dois, ou seja, 6 secrets ao todo. Cada PC **gera** o seu, apontando para o próprio IP, e o envia aos outros.

`fog1$` (pc-lamp-1):

```bash
cd ~ && $ISTIO/bin/istioctl x create-remote-secret --name=kind-fog1 \
  --server=https://192.168.0.11:6443 > secret-fog1.yaml
scp secret-fog1.yaml fog2: && scp secret-fog1.yaml cloud1:
```

`fog2$` (pc-lamp-2):

```bash
cd ~ && $ISTIO/bin/istioctl x create-remote-secret --name=kind-fog2 \
  --server=https://192.168.0.12:6443 > secret-fog2.yaml
scp secret-fog2.yaml fog1: && scp secret-fog2.yaml cloud1:
```

`cloud1$` (pc-lamp-3):

```bash
cd ~ && $ISTIO/bin/istioctl x create-remote-secret --name=kind-cloud1 \
  --server=https://192.168.0.13:6443 > secret-cloud1.yaml
scp secret-cloud1.yaml fog1: && scp secret-cloud1.yaml fog2:
```

No Istio 1.16, o comando é experimental (`istioctl x create-remote-secret`). Nas versões do fallback, ele virou `istioctl create-remote-secret`.

Depois, em cada PC, aplique os dois secrets recebidos.

`fog1$` (pc-lamp-1):

```bash
kubectl apply -f ~/secret-fog2.yaml -f ~/secret-cloud1.yaml
```

`fog2$` (pc-lamp-2):

```bash
kubectl apply -f ~/secret-fog1.yaml -f ~/secret-cloud1.yaml
```

`cloud1$` (pc-lamp-3):

```bash
kubectl apply -f ~/secret-fog1.yaml -f ~/secret-fog2.yaml
```

`clusters$` (pc-lamp-1 a 3) confira:

```bash
kubectl -n istio-system get secrets -l istio/multiCluster=true    # dois secrets istio-remote-secret-*
```

`Prototype_Setup/cluster-setup/secret_sample.yaml` mostra o formato esperado. **Nunca** commite secrets reais: eles dão acesso administrativo ao cluster.

### 6. Teste com o helloworld

`clusters$` (pc-lamp-1 a 3) crie o namespace e o Service:

```bash
kubectl create ns sample && kubectl label ns sample istio-injection=enabled
kubectl -n sample apply -f $ISTIO/samples/helloworld/helloworld.yaml -l service=helloworld
```

O Service `helloworld` precisa existir **em todos os clusters**, para que o nome DNS resolva localmente. Os pods ficam distribuídos.

`fog1$` (pc-lamp-1) implante o v1 e o `sleep`, de onde saem as requisições:

```bash
kubectl -n sample apply -f $ISTIO/samples/helloworld/helloworld.yaml -l version=v1
kubectl -n sample apply -f $ISTIO/samples/sleep/sleep.yaml
```

`fog2$` (pc-lamp-2) e `cloud1$` (pc-lamp-3) implantem o v2:

```bash
kubectl -n sample apply -f $ISTIO/samples/helloworld/helloworld.yaml -l version=v2
```

`fog1$` (pc-lamp-1) faça 10 requisições:

```bash
for i in $(seq 10); do
  kubectl -n sample exec deploy/sleep -c sleep -- curl -sS helloworld.sample:5000/hello
done
```

### 7. Guardar a configuração

`carga$` (pc-lamp-5) copie `~/clusters` e `~/certs*` de cada PC, como no M1, passo 5. O `~/certs` do fog1 guarda a CA raiz: sem ele, um cluster novo (o fog3, por exemplo) não entra na malha sem refazer os certificados de todos.

```bash
for h in fog1 fog2 cloud1; do
  mkdir -p ~/backup/$h
  scp -r "$h:clusters" "$h:certs*" ~/backup/$h/
done
ls ~/backup/fog1/certs/root-ca.conf ~/backup/fog1/certs/root-key.pem    # a CA raiz
```

## O que observar

- As respostas alternam entre `v1` (fog1) e `v2`. O nome da instância mostra se a v2 veio do fog2 ou do cloud1: compare com `kubectl -n sample get pods` em cada PC.
- `fog1$` (pc-lamp-1) veja como o sidecar do sleep enxerga os endpoints:

  ```bash
  $ISTIO/bin/istioctl proxy-config endpoints deploy/sleep.sample \
    --cluster "outbound|5000||helloworld.sample.svc.cluster.local"
  ```

  O endpoint local aparece com o IP do pod. Os remotos aparecem como `192.168.0.12:15443` e `192.168.0.13:15443`, ou seja, **os gateways**, não os pods.

## Verifique seu entendimento

1. Antes de rodar: se você apagar o pod v2 do fog2, o que acontece com as respostas no fog1? Rode e confira.
2. Pare o cluster cloud1 (`cloud1$ docker stop cloud1-control-plane cloud1-worker`; depois, `docker start`). Quanto tempo leva até as respostas pararem de tentar o cloud1? Que recurso do Istio (que o MicroFog usa nos data stores) controlaria isso?
3. Por que a CA comum é necessária? O que você esperaria ver se o fog2 tivesse uma CA própria?
4. Na Fig. 7 do artigo, as requisições entre CEs são roteadas pelo cabeçalho `cluster`. Que recurso do Istio, visto aqui, permite isso?

## Problemas comuns

| Sintoma | Causa provável | Diagnóstico |
|---|---|---|
| Só responde `v1` | Remote secrets ausentes ou inválidos | `kubectl -n istio-system logs deploy/istiod \| grep -i -E "remote\|cluster"` |
| `upstream connect error` / reset nas chamadas remotas | CA diferente entre clusters, ou `meshNetworks` com IP errado | `istioctl proxy-config endpoints` e logs do sidecar do sleep |
| `curl https://<IP>:6443` falha com erro de certificado | SAN do API server sem o IP | M1, passo 2 |
| `EXTERNAL-IP` do east-west em `<pending>` | O pool do MetalLB não contém o IP do PC | `kubectl -n metallb-system get ipaddresspool -o yaml` |
| `istiod` em `Pending` | Requests maiores que o allocatable de algum nó | `kubectl -n istio-system describe pod -l app=istiod` |

## Registro de execução

- Data:
- Versão do Istio:
- Precisou mudar algo nos arquivos `istio-*.yaml`?
- Saída do teste helloworld (resumo):
- Desvios do plano:
