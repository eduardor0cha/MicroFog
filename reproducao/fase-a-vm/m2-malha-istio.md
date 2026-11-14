# M2 — Malha Istio multi-cluster

## Objetivo

Os três clusters formam **uma única malha de serviços** (Istio *multi-primary, multi-network*). A prova: um pod no fog1 chama `helloworld.sample:5000` e recebe respostas de pods que estão no fog2 e no cloud1.

Esta é a parte mais frágil de toda a reprodução. Faça com calma e tire snapshot antes.

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
| `<cluster>/istio-<cluster>.yaml` | `IstioOperator`: nome do cluster, rede, east-west gateway (com `loadBalancerIP` = IP da VM) e ingress gateway |
| `istio-cross-gateway.yaml` | Abre a 15443 do east-west para os serviços `*.local` |
| `apiserver-gateway.yaml` + `apiserver-vs.yaml` | Expõem o API server na porta 6443 do east-west, para os remote secrets |

## Passos

Versão do Istio: a definida no portão do [M1](m1-clusters.md#portão-gono-go-de-versões). Abaixo, `$ISTIO` é o diretório extraído (ex.: `~/istio-1.16.7`).

### 1. CA raiz comum

`fog1$` Gere uma CA raiz e um certificado intermediário por cluster. Isso só é feito no fog1.

```bash
mkdir -p ~/certs && cd ~/certs
make -f $ISTIO/tools/certs/Makefile.selfsigned.mk root-ca
for c in fog1 fog2 cloud1; do make -f $ISTIO/tools/certs/Makefile.selfsigned.mk $c-cacerts; done
scp -r ~/certs/fog2   fog2:~/certs-fog2
scp -r ~/certs/cloud1 cloud1:~/certs-cloud1
```

`todas$` Crie o secret `cacerts` **antes** de instalar o Istio. Exemplo no fog1; nas outras VMs, troque o diretório:

```bash
kubectl create namespace istio-system
kubectl -n istio-system create secret generic cacerts \
  --from-file=$HOME/certs/fog1/ca-cert.pem --from-file=$HOME/certs/fog1/ca-key.pem \
  --from-file=$HOME/certs/fog1/root-cert.pem --from-file=$HOME/certs/fog1/cert-chain.pem
```

### 2. Rede do namespace e instalação

`todas$` (fog1 → `network1`, fog2 → `network2`, cloud1 → `network3`, como nos arquivos do repositório):

```bash
kubectl label namespace istio-system topology.istio.io/network=network1

sed "s/<PUBLIC_IP_OF_THE_VM>/<IP_FOG1>/" \
  ~/MicroFog/Prototype_Setup/cluster-setup/fog1/istio-fog1.yaml > ~/clusters/istio-fog1.yaml

$ISTIO/bin/istioctl install -y -f ~/clusters/istio-fog1.yaml \
  --set components.pilot.k8s.resources.requests.cpu=100m \
  --set components.pilot.k8s.resources.requests.memory=512Mi
```

Por que reduzir os *requests* do `istiod`: o padrão (500m / 2 GiB) não cabe nos nós pequenos do M1, e o que o Istio reserva **some do allocatable que o CE enxerga** para as aplicações.

```bash
kubectl -n istio-system get pods,svc -o wide
```

O Service `istio-eastwestgateway` deve ter `EXTERNAL-IP` = IP da VM (vindo do MetalLB).

### 3. Gateways entre clusters

`todas$`

```bash
cd ~/MicroFog/Prototype_Setup/cluster-setup
kubectl -n istio-system apply -f istio-cross-gateway.yaml
kubectl -n istio-system apply -f apiserver-gateway.yaml -f apiserver-vs.yaml
```

Teste a partir de **outra** VM: o API server do fog1 deve responder através do gateway, com certificado válido para o IP (M1, passo 2):

```bash
fog2$ curl -k https://<IP_FOG1>:6443/version
```

### 4. `meshNetworks`

`todas$` Diga a cada `istiod` onde fica o gateway de cada rede:

```bash
kubectl -n istio-system edit configmap istio
```

Dentro de `data.mesh`, acrescente:

```yaml
meshNetworks:
  networks:
    network1:
      endpoints: [{fromRegistry: kind-fog1}]
      gateways: [{address: <IP_FOG1>, port: 15443}]
    network2:
      endpoints: [{fromRegistry: kind-fog2}]
      gateways: [{address: <IP_FOG2>, port: 15443}]
    network3:
      endpoints: [{fromRegistry: kind-cloud1}]
      gateways: [{address: <IP_CLOUD1>, port: 15443}]
```

`kind-fog1` etc. são os `clusterName` definidos nos arquivos `istio-*.yaml`.

### 5. Remote secrets

Cada cluster precisa de um secret de cada um dos outros dois, ou seja, 6 secrets ao todo. Cada VM **gera** o seu, apontando para o próprio IP, e o envia às outras:

```bash
fog1$ $ISTIO/bin/istioctl x create-remote-secret --name=kind-fog1 \
        --server=https://<IP_FOG1>:6443 > secret-fog1.yaml
fog1$ scp secret-fog1.yaml fog2: && scp secret-fog1.yaml cloud1:
```

No Istio 1.16, o comando é experimental (`istioctl x create-remote-secret`). Nas versões do fallback, ele virou `istioctl create-remote-secret`.

Repita no fog2 e no cloud1. Depois, em cada VM, aplique os dois secrets recebidos:

```bash
fog2$ kubectl apply -f secret-fog1.yaml -f secret-cloud1.yaml
```

`Prototype_Setup/cluster-setup/secret_sample.yaml` mostra o formato esperado. **Nunca** commite secrets reais: eles dão acesso administrativo ao cluster.

### 6. Teste com o helloworld

`todas$`

```bash
kubectl create ns sample && kubectl label ns sample istio-injection=enabled
kubectl -n sample apply -f $ISTIO/samples/helloworld/helloworld.yaml -l service=helloworld
```

O Service `helloworld` precisa existir **em todos os clusters**, para que o nome DNS resolva localmente. Os pods ficam distribuídos:

```bash
fog1$   kubectl -n sample apply -f $ISTIO/samples/helloworld/helloworld.yaml -l version=v1
fog1$   kubectl -n sample apply -f $ISTIO/samples/sleep/sleep.yaml
fog2$   kubectl -n sample apply -f $ISTIO/samples/helloworld/helloworld.yaml -l version=v2
cloud1$ kubectl -n sample apply -f $ISTIO/samples/helloworld/helloworld.yaml -l version=v2
```

```bash
fog1$ for i in $(seq 10); do
        kubectl -n sample exec deploy/sleep -c sleep -- curl -sS helloworld.sample:5000/hello
      done
```

### 7. Snapshot

Snapshot `m2` das três VMs.

## O que observar

- As respostas alternam entre `v1` (fog1) e `v2`. O nome da instância mostra se a v2 veio do fog2 ou do cloud1: compare com `kubectl -n sample get pods` em cada VM.
- Veja como o sidecar do sleep enxerga os endpoints:

  ```bash
  fog1$ $ISTIO/bin/istioctl proxy-config endpoints deploy/sleep.sample \
          --cluster "outbound|5000||helloworld.sample.svc.cluster.local"
  ```

  O endpoint local aparece com o IP do pod. Os remotos aparecem como `<IP_FOG2>:15443` e `<IP_CLOUD1>:15443`, ou seja, **os gateways**, não os pods.

## Verifique seu entendimento

1. Antes de rodar: se você apagar o pod v2 do fog2, o que acontece com as respostas no fog1? Rode e confira.
2. Pare a VM cloud1. Quanto tempo leva até as respostas pararem de tentar o cloud1? Que recurso do Istio (que o MicroFog usa nos data stores) controlaria isso?
3. Por que a CA comum é necessária? O que você esperaria ver se o fog2 tivesse uma CA própria?
4. Na Fig. 7 do artigo, as requisições entre CEs são roteadas pelo cabeçalho `cluster`. Que recurso do Istio, visto aqui, permite isso?

## Problemas comuns

| Sintoma | Causa provável | Diagnóstico |
|---|---|---|
| Só responde `v1` | Remote secrets ausentes ou inválidos | `kubectl -n istio-system logs deploy/istiod \| grep -i -E "remote\|cluster"` |
| `upstream connect error` / reset nas chamadas remotas | CA diferente entre clusters, ou `meshNetworks` com IP errado | `istioctl proxy-config endpoints` e logs do sidecar do sleep |
| `curl https://<IP>:6443` falha com erro de certificado | SAN do API server sem o IP | M1, passo 2 |
| `EXTERNAL-IP` do east-west em `<pending>` | O pool do MetalLB não contém o IP da VM | `kubectl -n metallb-system get ipaddresspool -o yaml` |
| `istiod` em `Pending` | Requests maiores que o allocatable de algum nó | `kubectl -n istio-system describe pod -l app=istiod` |

## Registro de execução

- Data:
- Versão do Istio:
- Precisou mudar algo nos arquivos `istio-*.yaml`?
- Saída do teste helloworld (resumo):
- Desvios do plano:
