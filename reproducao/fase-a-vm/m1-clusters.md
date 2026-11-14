# M1 — Clusters Kubernetes

## Objetivo

Um cluster KinD em cada VM (`fog1`, `fog2`, `cloud1`), com nós rotulados por região e zona, *metrics-server* e MetalLB, e com o certificado do API server aceitando o IP da VM.

## Conceitos

### Kubernetes em 5 minutos (§2.3.2)

- **Nó**: máquina (aqui, um container) que roda pods. Um nó **control-plane** roda o API server e o scheduler; os **workers** rodam as aplicações.
- **Pod**: a menor unidade implantável, com um ou mais containers. Cada microserviço do MicroFog vira um pod.
- **Service**: nome DNS estável (ex.: `hcm2.hcapp.svc.cluster.local`) que distribui o tráfego entre os pods de um microserviço.
- **Namespace**: separação lógica. Cada aplicação tem o seu (`hcapp`, `app2`); o CE vive em `control-engine`.
- **ConfigMap**: configuração em pares chave-valor que os pods leem. Tanto o CE quanto os microserviços de teste são configurados assim.
- **allocatable**: quanto de CPU e memória do nó **pode ser reservado** por pods. É o que o CE consulta para decidir onde cabe cada microserviço (`controllers/CommandHandler.java`, método `getAllNodes`).

### Como o KinD emula nós heterogêneos (Tabela 2)

Cada nó KinD é um container que **enxerga todos os recursos do host**. Para que o "nó 1" pareça ter 3 vCPU numa VM de 16 vCPU, os autores reservam o resto para o "sistema" com o parâmetro `system-reserved` do kubelet:

```
allocatable ≈ recursos do host − system-reserved − limiar de despejo (~100 Mi)
```

No `Prototype_Setup/cluster-setup/fog1/kindClusterConfig-fog1.yaml` original, `system-reserved: memory=58Gi,cpu=13` numa VM de 16 vCPU / 64 GB resulta em ~3 vCPU / ~6 GB, que é o "node1 (control-node)" da Tabela 2.

Isso é **contabilidade, não isolamento**: todos os nós continuam disputando as mesmas CPUs reais. O placement respeita os tamanhos lógicos, mas o desempenho real é compartilhado.

### Região e zona

Os rótulos `topology.kubernetes.io/region` (`fog`/`cloud`) e `topology.kubernetes.io/zone` (nome do cluster) são usados pelo Istio no **failover por localidade** dos data stores (M3, M9): primeiro a mesma zona, depois a mesma região, depois as outras.

### MetalLB

Num provedor de nuvem, um Service do tipo `LoadBalancer` ganha um IP externo automaticamente. Em bare metal ou KinD isso não acontece. O **MetalLB** faz esse papel, e os gateways do Istio (M2) dependem dele.

## Portão go/no-go de versões

Decisão D13: tentar primeiro as versões da época do artigo.

| Componente | Versões de 2022 ("GO") | Fallback atual ("NO-GO") |
|---|---|---|
| kind | v0.14.0 | última versão estável |
| Imagem do nó | `kindest/node:v1.24.0@sha256:0866296e…` (a do repositório) | a padrão da versão do kind |
| Istio | 1.16.x | a última que suporte essa versão de Kubernetes |
| MetalLB | v0.13.7 | a última versão estável |
| metrics-server | v0.6.4 | a última versão estável |

`fog1$` Teste, em até ~30 minutos:

```bash
# kind v0.14.0
curl -Lo kind https://kind.sigs.k8s.io/dl/v0.14.0/kind-linux-amd64 && chmod +x kind && sudo mv kind /usr/local/bin/
kind create cluster --name gate \
  --image kindest/node:v1.24.0@sha256:0866296e693efe1fed79d5e6c7af8df71fc73ae45e3679af05342239cdc5bc8e
kubectl get nodes                       # Ready?
kubectl -n kube-system get pods         # coredns Running?

# Istio 1.16
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.16.7 sh -
~/istio-1.16.7/bin/istioctl install --set profile=minimal -y
kubectl -n istio-system get pods        # istiod Running?

kind delete cluster --name gate
```

- **GO**: o nó fica `Ready`, CoreDNS e istiod em `Running`. Use as versões de 2022 em tudo.
- **NO-GO**: algum desses passos falha. Registre o erro exato no Registro de execução, troque para o fallback e anote as versões em `decisoes.md` (D13).

Instale a mesma versão de `kind` e `istioctl` nas três VMs.

## Passos

### 1. Configuração reduzida dos clusters

Decisão D10: fog1 e fog2 com 1 control-plane + 2 workers; cloud1 com 1 control-plane + 1 worker. VMs de 4 vCPU / 8 GB. Valores iniciais de `system-reserved`:

| Cluster | Nó | system-reserved | allocatable aproximado | Papel |
|---|---|---|---|---|
| fog1 | control-plane | `cpu=3,memory=6Gi` | 1 vCPU / 1,9 GB | |
| fog1 | worker | `cpu=2,memory=5Gi` | 2 vCPU / 2,9 GB | gateways do Istio (portas mapeadas) |
| fog1 | worker2 | `cpu=3,memory=6Gi` | 1 vCPU / 1,9 GB | |
| fog2 | control-plane | `cpu=3,memory=6Gi` | 1 vCPU / 1,9 GB | |
| fog2 | worker | `cpu=2,memory=5Gi` | 2 vCPU / 2,9 GB | gateways do Istio |
| fog2 | worker2 | `cpu=2.5,memory=5.5Gi` | 1,5 vCPU / 2,4 GB | |
| cloud1 | control-plane | `cpu=2,memory=4Gi` | 2 vCPU / 3,9 GB | |
| cloud1 | worker | `cpu=1,memory=4Gi` | 3 vCPU / 3,9 GB | gateways do Istio |

Os fogs são **pequenos de propósito**: no M6, um PR com throughput maior não pode caber no fog1, para forçar o forwarding. Se o Istio ou o CE não couberem, ajuste estes números e registre.

`fog1$` Crie `~/clusters/kind-fog1.yaml` a partir do original, mantendo a estrutura e mudando só a quantidade de nós e as reservas:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: fog1
nodes:
  - role: control-plane
    image: kindest/node:v1.24.0@sha256:0866296e693efe1fed79d5e6c7af8df71fc73ae45e3679af05342239cdc5bc8e  # ou a do fallback
    kubeadmConfigPatches:
    - |
      kind: InitConfiguration
      nodeRegistration:
        kubeletExtraArgs:
          system-reserved: memory=6Gi,cpu=3
    labels:
      topology.kubernetes.io/region: fog
      topology.kubernetes.io/zone: fog1
  - role: worker
    image: kindest/node:v1.24.0@sha256:0866296e693efe1fed79d5e6c7af8df71fc73ae45e3679af05342239cdc5bc8e
    kubeadmConfigPatches:
    - |
      kind: JoinConfiguration
      nodeRegistration:
        kubeletExtraArgs:
          system-reserved: memory=5Gi,cpu=2
    extraPortMappings:          # porta do host → nodePort dos gateways do Istio (M2)
      - containerPort: 32012    # east-west gateway (tráfego entre clusters)
        hostPort: 15443
      - containerPort: 32022    # ingress gateway (usuários, PRs)
        hostPort: 80
      - containerPort: 32032    # API server exposto aos outros clusters
        hostPort: 6443
    labels:
      istioingress: enable
      istioeastwest: enable
      topology.kubernetes.io/region: fog
      topology.kubernetes.io/zone: fog1
  - role: worker
    image: kindest/node:v1.24.0@sha256:0866296e693efe1fed79d5e6c7af8df71fc73ae45e3679af05342239cdc5bc8e
    kubeadmConfigPatches:
    - |
      kind: JoinConfiguration
      nodeRegistration:
        kubeletExtraArgs:
          system-reserved: memory=6Gi,cpu=3
    labels:
      topology.kubernetes.io/region: fog
      topology.kubernetes.io/zone: fog1

# Mantidos do original: kubelet sem autorização por webhook (simplifica o acesso do
# metrics-server) e agregação de APIs roteada pelo API server (usada pela Metrics API).
kubeadmConfigPatches:
- |
  kind: InitConfiguration
  nodeRegistration:
    kubeletExtraArgs:
      authorization-mode: "AlwaysAllow"
- |
  kind: ClusterConfiguration
  apiServer:
    extraArgs:
      enable-aggregator-routing: "true"
```

Repita no `fog2` (com `zone: fog2`) e no `cloud1` (com `region: cloud`, `zone: cloud1`), usando os valores da tabela.

Diferenças em relação ao original e por quê:
- Removemos os `extraMounts` (`./data_*`): não são usados pelo CE e exigiriam diretórios no host.
- No original, o patch `enable-aggregator-routing` estava repetido em cada worker, onde não tem efeito (`ClusterConfiguration` só vale para o control-plane). Aqui ele aparece uma vez, no nível do cluster.

```bash
fog1$ kind create cluster --config ~/clusters/kind-fog1.yaml
fog1$ kubectl get nodes -L topology.kubernetes.io/region,topology.kubernetes.io/zone
```

### 2. Certificado do API server com o IP da VM

No M2, os outros clusters vão acessar o API server deste cluster em `https://<IP_FOG1>:6443`, passando pelo gateway do Istio. O certificado do API server precisa incluir esse IP, ou a conexão TLS é recusada.

`fog1$` (em cada VM, só para o próprio cluster):

```bash
CP=fog1-control-plane          # fog2-control-plane / cloud1-control-plane
IP=<IP_FOG1>

kubectl -n kube-system get configmap kubeadm-config \
  -o jsonpath='{.data.ClusterConfiguration}' > kubeadm.yaml
# Edite kubeadm.yaml: em apiServer.certSANs, acrescente o $IP à lista.

docker cp kubeadm.yaml $CP:/etc/kubernetes/pki/kubeadm.yaml
docker exec $CP rm /etc/kubernetes/pki/apiserver.crt /etc/kubernetes/pki/apiserver.key
docker exec $CP kubeadm init phase certs apiserver --config /etc/kubernetes/pki/kubeadm.yaml
```

Confira:

```bash
docker cp $CP:/etc/kubernetes/pki/apiserver.crt /tmp/apiserver.crt
openssl x509 -in /tmp/apiserver.crt -noout -ext subjectAltName    # deve listar o $IP
```

O kube-apiserver recarrega o certificado do disco sozinho. Se não recarregar, reinicie o container do nó: `docker restart $CP`.

### 3. metrics-server

O CE usa o uso real dos nós (`kubectl top`), além do allocatable.

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.6.4/components.yaml
kubectl -n kube-system patch deployment metrics-server --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
kubectl top nodes       # aguarde ~1 min
```

`--kubelet-insecure-tls` é necessário no KinD porque os certificados dos kubelets não incluem os IPs dos containers.

### 4. MetalLB

```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.7/config/manifests/metallb-native.yaml
kubectl -n metallb-system wait --for=condition=Ready pod --all --timeout=180s
sed "s/<PUBLIC_IP_OF_THE_VM>/<IP_FOG1>/" \
  ~/MicroFog/Prototype_Setup/cluster-setup/fog1/ip_pool_fog1.yaml | kubectl apply -f -
```

O pool tem duas partes: a faixa `172.18.255.x`, dentro da rede Docker `kind`, e o IP da VM (`/32`). O IP da VM vai para o east-west gateway (M2), e é ele que os outros clusters usam.

### 5. Snapshot

Tire um snapshot `m1` das três VMs.

## O que observar

```bash
kubectl get nodes -o custom-columns=NOME:.metadata.name,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory
```

Compare o allocatable de cada nó com a tabela do passo 1. É exatamente isso que o CE vai "ver".

## Verifique seu entendimento

1. Rode `docker ps` na VM. Quantos containers você vê? Qual a relação com `kubectl get nodes`?
2. `kubectl top nodes` mostra o mesmo uso de CPU para todos os nós, ou um diferente para cada? Por quê, se todos compartilham a mesma VM?
3. Mude o `system-reserved` de um worker, recrie o cluster e confira o novo allocatable. Que impacto isso teria num placement do V1 (sem escalonamento horizontal)?
4. Por que os três clusters podem usar a mesma porta 15443 do host sem conflito? Isso funcionaria se estivessem numa VM só?

## Problemas comuns

| Sintoma | Causa provável | Diagnóstico |
|---|---|---|
| `kind create` trava em "Starting control-plane" | Imagem antiga do nó incompatível com o kernel/cgroup do host | `docker logs fog1-control-plane`; é o caso NO-GO do portão |
| Pods em `CrashLoopBackOff` com "too many open files" | Limites de inotify | Passo 5 do [00](00-preparar-vms.md) |
| `kubectl top` → "metrics not available" | Falta `--kubelet-insecure-tls` ou ainda não houve coleta | `kubectl -n kube-system logs deploy/metrics-server` |
| Nó `NotReady` por falta de memória | `system-reserved` somado maior que a VM | `kubectl describe node` |

## Registro de execução

- Data:
- Resultado do portão: GO / NO-GO (erro):
- Versões usadas (kind, imagem do nó, Istio, MetalLB, metrics-server):
- `system-reserved` finais:
- Desvios do plano:
