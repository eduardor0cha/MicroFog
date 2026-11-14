# fog3 com k3d

## Objetivo

Criar o quarto cluster do artigo, **fog3**, com **k3d** (k3s em containers) no PC4, e integrá-lo à malha, aos data stores e aos CEs. O repositório **não traz nenhum arquivo** para o fog3. Tudo aqui é montado a partir da Tabela 2 e do texto da §6.1.1.

## Conceitos

### k8s × k3s (§6.1.1, Fig. 14)

O **k3s** é uma distribuição Kubernetes leve, feita para dispositivos com poucos recursos: um único binário, SQLite no lugar do etcd por padrão, menos componentes. O **k3d** está para o k3s como o KinD está para o k8s: cada nó vira um container Docker.

Na Fig. 14, o deploy no fog3 (k3s) foi **mais rápido** que no fog1 (k8s), o que mostra que o MicroFog funciona em distribuições diferentes. Recriar o fog3 é o que permite reproduzir esse experimento (E4) e o cenário 3 do E3.

### O que o fog3 precisa (comparando com o fog1)

| Item | fog1 (KinD) | fog3 (k3d) |
|---|---|---|
| Nós (Tabela 2) | control-plane + 3 workers | 1 server + 2 agents |
| Contexto kubectl | `kind-fog1` | `k3d-fog3` |
| `clusterName` / rede do Istio | `kind-fog1` / `network1` | `k3d-fog3` / `network4` |
| SAN do certificado | regenerado com kubeadm (M1, passo 2) | `--tls-san` na criação |
| Load balancer | MetalLB | MetalLB (desativar o `servicelb` do k3s) |
| Ingress | Istio | Istio (desativar o Traefik do k3s) |

## Passos

### 1. Versões

Use uma imagem `rancher/k3s` com a **mesma versão de Kubernetes** dos outros clusters, conforme o portão do M1. No caso GO, uma `v1.24.x-k3s1`. Escolha uma versão do k3d que suporte essa imagem e registre ambas.

### 2. Criar o cluster

`fog3$` (os `system-reserved` seguem a proposta × 0,5 de [m1-m7-nos-pcs.md](m1-m7-nos-pcs.md); recalcule para o seu PC):

```bash
k3d cluster create fog3 \
  --image rancher/k3s:v1.24.17-k3s1 \
  --servers 1 --agents 2 \
  --k3s-arg "--disable=traefik@server:0" \
  --k3s-arg "--disable=servicelb@server:0" \
  --k3s-arg "--tls-san=192.168.0.14@server:0" \
  --k3s-arg "--kubelet-arg=system-reserved=cpu=2.5,memory=20Gi@server:0" \
  --k3s-arg "--kubelet-arg=system-reserved=cpu=3,memory=21Gi@agent:0" \
  --k3s-arg "--kubelet-arg=system-reserved=cpu=3,memory=21Gi@agent:1" \
  -p "15443:32012@agent:0" -p "80:32022@agent:0" -p "6443:32032@agent:0" \
  --k3s-node-label "topology.kubernetes.io/region=fog@server:0;agent:*" \
  --k3s-node-label "topology.kubernetes.io/zone=fog3@server:0;agent:*" \
  --k3s-node-label "istioingress=enable@agent:0" \
  --k3s-node-label "istioeastwest=enable@agent:0"
```

A sintaxe das opções muda entre versões do k3d (por exemplo, `--k3s-node-label` versus `--k3s-arg "--node-label=..."`). Confira com `k3d cluster create --help` e registre o comando que funcionou.

O mapeamento de portas usa os **mesmos nodePorts** dos arquivos do Istio do repositório (32012, 32022, 32032), para reaproveitar a configuração do fog1.

```bash
kubectl get nodes -L topology.kubernetes.io/region,topology.kubernetes.io/zone
kubectl get nodes -o custom-columns=NOME:.metadata.name,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory
```

### 3. metrics-server e MetalLB

O k3s já traz o metrics-server. O MetalLB é instalado como no M1, passo 4, com um pool `fog3-pool` contendo `192.168.0.14/32` e uma faixa da rede Docker do k3d (veja com `docker network inspect k3d-fog3`).

### 4. Istio

- CA: gere `fog3-cacerts` com a mesma CA raiz do M2 (passo 1), **no PC onde está a CA raiz**.
- `istio-fog3.yaml`: copie `Prototype_Setup/cluster-setup/fog1/istio-fog1.yaml`, troque `clusterName: k3d-fog3`, `network: network4` (todas as ocorrências) e `loadBalancerIP: 192.168.0.14`.
- `kubectl label namespace istio-system topology.istio.io/network=network4`
- Aplique `istio-cross-gateway.yaml`, `apiserver-gateway.yaml` e `apiserver-vs.yaml`.
- **Nos quatro clusters**: acrescente `network4` (`fromRegistry: k3d-fog3`, gateway `192.168.0.14:15443`) ao `meshNetworks`.
- Remote secrets: gere o do fog3 (`--name=k3d-fog3 --server=https://192.168.0.14:6443`) e aplique nos outros três; aplique no fog3 os secrets dos outros três.
- Teste com o helloworld (M2, passo 6), agora com uma instância no fog3.

### 5. Data stores e CE

- MinIO/Redis: o artigo (E1) mantém data stores em fog1, fog2 e cloud1. O fog3 acessa os stores **pela malha**. Mesmo sem uma instância local, aplique no fog3 o Service `minio`, o Service `redis`, os VS e as DR, para que o nome DNS resolva.
- CE: crie `controller-configmap-fog3.yaml` (a partir do fog2) com `cluster.name = fog3`, vizinhos e `forwardpolicy`; e `controller-fog3.yaml` com o rótulo `cluster: fog3`.
- **Em todos os clusters**: acrescente o subset `fog3` à `control-engine-dr` e a rota `cluster: fog3` ao `control-engine-vs`.
- Nos CEs do fog1, fog2 e cloud1, acrescente `fog3` como vizinho (`fog.adjacent.cluster[n] = fog3`) e reinicie os pods.

## O que observar

- `curl -H "Host: control-engine.control-engine.svc.cluster.local" -H "cluster: fog3" http://192.168.0.11/MicroFog/home` responde "… - fog3".
- Um PR do hcApp com `entryClusters: ["fog3"]` submetido ao fog3: compare o tempo `NEW_PR_RECEIVED` → `PLACEMENT_COMPLETED` com o mesmo PR no fog1 (esboço do E4).

## Verifique seu entendimento

1. Liste os pods de sistema do fog3 e do fog1 (`kubectl get pods -A`). Quais componentes do k8s não existem no k3s?
2. Por que desativar o Traefik e o `servicelb` do k3s?
3. Quantos remote secrets existem na malha com 4 clusters? E com *n*?

## Registro de execução

- Data:
- Versões de k3d e da imagem k3s:
- Comando `k3d cluster create` que funcionou:
- Ajustes feitos nos outros clusters:
