# M1 — Clusters Kubernetes

## Objetivo

Um cluster KinD em cada PC de cluster (`fog1`, `fog2`, `cloud1`), com a **topologia de nós da Tabela 2** (fog1: 4 nós, fog2: 5, cloud1: 2), nós rotulados por região e zona, *metrics-server* e MetalLB, e com o certificado do API server aceitando o IP do PC.

O fog3 (k3d) entra depois, em [fog3-k3d.md](fog3-k3d.md). Até o M7, a malha tem três clusters.

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

O portão existe porque o artigo usou versões de 2022, e um kernel de 2026 com cgroup v2 pode não rodar a imagem antiga do nó. O teste curto no fog1 decide a versão antes de qualquer configuração ser feita em cima dela.

`todas$` (PCs 1–5) instale a mesma versão de `kind` e `istioctl` em todos. Com NO-GO, troque as duas versões pelas do fallback, anotadas em `decisoes.md`:

```bash
KIND_VERSION=v0.14.0
ISTIO_VERSION=1.16.7

curl -Lo kind https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64
sudo install -m 0755 kind /usr/local/bin/kind && rm kind

cd ~ && curl -L https://istio.io/downloadIstio | ISTIO_VERSION=$ISTIO_VERSION sh -
sudo install -m 0755 ~/istio-$ISTIO_VERSION/bin/istioctl /usr/local/bin/istioctl
```

O M2 usa os manifestos de exemplo que vêm com o Istio e se refere à pasta como `$ISTIO`. Grave a variável no `~/.bashrc` para ela valer em todo shell novo:

```bash
echo "export ISTIO=~/istio-$ISTIO_VERSION" >> ~/.bashrc
source ~/.bashrc
kind version && istioctl version --remote=false && ls $ISTIO/samples
```

## Tamanhos lógicos dos nós (questão em aberto A2)

Restrições:
- **Nenhum nó pode ter allocatable maior que o PC** (4 núcleos). A Tabela 2 tem nós de 5 e de 8 vCPU.
- A **memória** somada dos nós de um cluster deve caber na memória real do PC, porque memória não se compartilha como CPU: um *overcommit* termina em OOM.

**Proposta inicial: Tabela 2 × 0,5, em CPU e em memória.**

| Cluster | Nó (Tabela 2) | Tabela 2 | Alvo (× 0,5) |
|---|---|---|---|
| fog1 | control-plane / worker / worker2 / worker3 | 3/6, 4/9, 5/16, 3/8 | 1,5/3, 2/4,5, 2,5/8, 1,5/4 |
| fog2 | control-plane / worker / worker2 / worker3 / worker4 | 3/6, 3/9, 2/6, 4/12, 4/8 | 1,5/3, 1,5/4,5, 1/3, 2/6, 2/4 |
| fog3 | server / agent-0 / agent-1 | 3/6, 2/4, 2/4 | 1,5/3, 1/2, 1/2 |
| cloud1 | control-plane / worker | 8/14, 8/14 | 4/7, 4/7 |

(valores em vCPU / GB)

- Cada nó cabe no PC (≤ 4 núcleos), e a memória somada cabe nos PCs (fog1: 19,5; fog2: 20,5; cloud1: 14 de 24 GB; fog3: 7 de 16 GB).
- A CPU somada passa do real (fog1: 7,5 lógicos em 4 núcleos). Isso é *overcommit* de contabilidade, aceitável para "ver funcionando", mas que **distorce latências** quando a carga é alta.
- Os requisitos das aplicações (hcm2 = 1 CPU etc.) **não** foram reduzidos. A relação aplicação/infraestrutura é o dobro da do artigo, e o placement vai diferir da Tabela 3. Para a replicação fiel, considere também multiplicar por 0,5 os requisitos em `metadata/*.java` (é preciso recompilar o CE, M0).

### Do alvo ao `system-reserved`

O nó KinD enxerga a capacidade do PC inteiro, que você lê no próprio host:

```bash
fog1$ nproc                                                     # 4
fog1$ awk '/MemTotal/ {printf "%d Mi\n", $2/1024}' /proc/meminfo
```

```
system-reserved cpu    = 4 − alvo de CPU
system-reserved memory = MemTotal (Mi) − alvo de memória (Mi) − 100 Mi
```

A tabela abaixo supõe `MemTotal` = 23 552 Mi (23 GiB) nos PCs 1–3. Se o seu valor for outro, some a diferença a cada valor de memória.

| Cluster | Nó | Alvo | system-reserved | Papel |
|---|---|---|---|---|
| fog1 | control-plane | 1,5 / 3 Gi | `cpu=2.5,memory=20380Mi` | |
| fog1 | worker | 2 / 4,5 Gi | `cpu=2,memory=18844Mi` | gateways do Istio (portas mapeadas) |
| fog1 | worker2 | 2,5 / 8 Gi | `cpu=1.5,memory=15260Mi` | |
| fog1 | worker3 | 1,5 / 4 Gi | `cpu=2.5,memory=19356Mi` | |
| fog2 | control-plane | 1,5 / 3 Gi | `cpu=2.5,memory=20380Mi` | |
| fog2 | worker | 1,5 / 4,5 Gi | `cpu=2.5,memory=18844Mi` | gateways do Istio |
| fog2 | worker2 | 1 / 3 Gi | `cpu=3,memory=20380Mi` | |
| fog2 | worker3 | 2 / 6 Gi | `cpu=2,memory=17308Mi` | |
| fog2 | worker4 | 2 / 4 Gi | `cpu=2,memory=19356Mi` | |
| cloud1 | control-plane | 4 / 7 Gi | `cpu=0,memory=16284Mi` | |
| cloud1 | worker | 4 / 7 Gi | `cpu=0,memory=16284Mi` | gateways do Istio |

Registre os valores finais em `decisoes.md` (A2) e no Registro de execução.

## Passos

### 1. Configuração dos clusters

Cada PC guarda a configuração do seu cluster em `~/clusters/`. É essa pasta que o passo 5 copia para o `carga`, para recriar o cluster sem refazer as contas.

O arquivo de cada cluster parte do original em `Prototype_Setup/cluster-setup/<cluster>/kindClusterConfig-<cluster>.yaml`, com a mesma estrutura e as reservas da tabela acima. Com NO-GO, troque a linha `image:` de todos os nós pela imagem do fallback.

`fog1$`:

```bash
mkdir -p ~/clusters
cat > ~/clusters/kind-fog1.yaml <<'EOF'
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
          system-reserved: memory=20380Mi,cpu=2.5
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
          system-reserved: memory=18844Mi,cpu=2
    extraPortMappings:          # porta do PC → nodePort dos gateways do Istio (M2)
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
          system-reserved: memory=15260Mi,cpu=1.5
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
          system-reserved: memory=19356Mi,cpu=2.5
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
EOF
```

`fog2$` (5 nós; portas e rótulos `istioingress`/`istioeastwest` no **primeiro worker**):

```bash
mkdir -p ~/clusters
cat > ~/clusters/kind-fog2.yaml <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: fog2
nodes:
  - role: control-plane
    image: kindest/node:v1.24.0@sha256:0866296e693efe1fed79d5e6c7af8df71fc73ae45e3679af05342239cdc5bc8e
    kubeadmConfigPatches:
    - |
      kind: InitConfiguration
      nodeRegistration:
        kubeletExtraArgs:
          system-reserved: memory=20380Mi,cpu=2.5
    labels:
      topology.kubernetes.io/region: fog
      topology.kubernetes.io/zone: fog2
  - role: worker
    image: kindest/node:v1.24.0@sha256:0866296e693efe1fed79d5e6c7af8df71fc73ae45e3679af05342239cdc5bc8e
    kubeadmConfigPatches:
    - |
      kind: JoinConfiguration
      nodeRegistration:
        kubeletExtraArgs:
          system-reserved: memory=18844Mi,cpu=2.5
    extraPortMappings:
      - containerPort: 32012
        hostPort: 15443
      - containerPort: 32022
        hostPort: 80
      - containerPort: 32032
        hostPort: 6443
    labels:
      istioingress: enable
      istioeastwest: enable
      topology.kubernetes.io/region: fog
      topology.kubernetes.io/zone: fog2
  - role: worker
    image: kindest/node:v1.24.0@sha256:0866296e693efe1fed79d5e6c7af8df71fc73ae45e3679af05342239cdc5bc8e
    kubeadmConfigPatches:
    - |
      kind: JoinConfiguration
      nodeRegistration:
        kubeletExtraArgs:
          system-reserved: memory=20380Mi,cpu=3
    labels:
      topology.kubernetes.io/region: fog
      topology.kubernetes.io/zone: fog2
  - role: worker
    image: kindest/node:v1.24.0@sha256:0866296e693efe1fed79d5e6c7af8df71fc73ae45e3679af05342239cdc5bc8e
    kubeadmConfigPatches:
    - |
      kind: JoinConfiguration
      nodeRegistration:
        kubeletExtraArgs:
          system-reserved: memory=17308Mi,cpu=2
    labels:
      topology.kubernetes.io/region: fog
      topology.kubernetes.io/zone: fog2
  - role: worker
    image: kindest/node:v1.24.0@sha256:0866296e693efe1fed79d5e6c7af8df71fc73ae45e3679af05342239cdc5bc8e
    kubeadmConfigPatches:
    - |
      kind: JoinConfiguration
      nodeRegistration:
        kubeletExtraArgs:
          system-reserved: memory=19356Mi,cpu=2
    labels:
      topology.kubernetes.io/region: fog
      topology.kubernetes.io/zone: fog2

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
EOF
```

`cloud1$` (2 nós; `region: cloud`; portas e rótulos no worker):

```bash
mkdir -p ~/clusters
cat > ~/clusters/kind-cloud1.yaml <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: cloud1
nodes:
  - role: control-plane
    image: kindest/node:v1.24.0@sha256:0866296e693efe1fed79d5e6c7af8df71fc73ae45e3679af05342239cdc5bc8e
    kubeadmConfigPatches:
    - |
      kind: InitConfiguration
      nodeRegistration:
        kubeletExtraArgs:
          system-reserved: memory=16284Mi,cpu=0
    labels:
      topology.kubernetes.io/region: cloud
      topology.kubernetes.io/zone: cloud1
  - role: worker
    image: kindest/node:v1.24.0@sha256:0866296e693efe1fed79d5e6c7af8df71fc73ae45e3679af05342239cdc5bc8e
    kubeadmConfigPatches:
    - |
      kind: JoinConfiguration
      nodeRegistration:
        kubeletExtraArgs:
          system-reserved: memory=16284Mi,cpu=0
    extraPortMappings:
      - containerPort: 32012
        hostPort: 15443
      - containerPort: 32022
        hostPort: 80
      - containerPort: 32032
        hostPort: 6443
    labels:
      istioingress: enable
      istioeastwest: enable
      topology.kubernetes.io/region: cloud
      topology.kubernetes.io/zone: cloud1

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
EOF
```

Se o `MemTotal` do PC não for 23 552 Mi, corrija os valores de `memory=` antes de criar o cluster:

```bash
nano ~/clusters/kind-fog1.yaml     # kind-fog2.yaml no fog2, kind-cloud1.yaml no cloud1
```

Diferenças em relação ao original e por quê:
- Removemos os `extraMounts` (`./data_*`): não são usados pelo CE e exigiriam diretórios no host.
- No original, o patch `enable-aggregator-routing` estava repetido em cada worker, onde não tem efeito (`ClusterConfiguration` só vale para o control-plane). Aqui ele aparece uma vez, no nível do cluster.

`clusters$` crie o cluster (`fog1`, `fog2` ou `cloud1`, conforme o PC):

```bash
C=fog1
kind create cluster --config ~/clusters/kind-$C.yaml
kubectl get nodes -L topology.kubernetes.io/region,topology.kubernetes.io/zone
```

O KinD usa a rede Docker `kind` criada no [00](00-preparar-pcs-e-rede.md), passo 6 (`10.201.0.0/16`).

### 2. Certificado do API server com o IP do PC

No M2, os outros clusters vão acessar o API server deste cluster em `https://192.168.0.11:6443`, passando pelo gateway do Istio. O certificado do API server precisa incluir esse IP, ou a conexão TLS é recusada.

`clusters$` (em cada PC, só para o próprio cluster):

| PC | `CP` | `IP` |
|---|---|---|
| fog1 | `fog1-control-plane` | `192.168.0.11` |
| fog2 | `fog2-control-plane` | `192.168.0.12` |
| cloud1 | `cloud1-control-plane` | `192.168.0.13` |

```bash
CP=fog1-control-plane
IP=192.168.0.11

kubectl -n kube-system get configmap kubeadm-config \
  -o jsonpath='{.data.ClusterConfiguration}' > kubeadm.yaml
grep -A4 'certSANs:' kubeadm.yaml      # a lista atual: localhost, 127.0.0.1...
```

Acrescente o `$IP` à lista `apiServer.certSANs`. O `sed` insere a linha logo depois de `certSANs:`, com o mesmo recuo dos itens que já estão lá:

```bash
sed -i "s/^\(\s*\)certSANs:$/&\n\1- $IP/" kubeadm.yaml
grep -A5 'certSANs:' kubeadm.yaml      # o $IP deve aparecer na lista
```

Se o recuo sair diferente do dos outros itens, corrija à mão com `nano kubeadm.yaml`. Depois, gere o certificado novo dentro do nó control-plane:

```bash
docker cp kubeadm.yaml $CP:/etc/kubernetes/pki/kubeadm.yaml
docker exec $CP rm /etc/kubernetes/pki/apiserver.crt /etc/kubernetes/pki/apiserver.key
docker exec $CP kubeadm init phase certs apiserver --config /etc/kubernetes/pki/kubeadm.yaml
```

Confira:

```bash
docker cp $CP:/etc/kubernetes/pki/apiserver.crt /tmp/apiserver.crt
openssl x509 -in /tmp/apiserver.crt -noout -ext subjectAltName    # deve listar o $IP
```

O kube-apiserver recarrega o certificado do disco sozinho. Para conferir o certificado que ele está servindo de fato, conecte-se ao endereço que o `kubectl` usa:

```bash
SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' | sed 's#https://##')
echo | openssl s_client -connect $SERVER 2>/dev/null | openssl x509 -noout -ext subjectAltName    # deve listar o $IP
```

Se o `$IP` não aparecer, reinicie o container do nó e repita a conferência:

```bash
docker restart $CP
```

### 3. metrics-server

O CE usa o uso real dos nós (`kubectl top`), além do allocatable.

`clusters$` (fog1, fog2 e cloud1):

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.6.4/components.yaml
kubectl -n kube-system patch deployment metrics-server --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
kubectl top nodes       # aguarde ~1 min
```

`--kubelet-insecure-tls` é necessário no KinD porque os certificados dos kubelets não incluem os IPs dos containers.

### 4. MetalLB

`clusters$` (troque `C` e `IP` conforme o PC: `fog1`/`192.168.0.11`, `fog2`/`192.168.0.12`, `cloud1`/`192.168.0.13`):

```bash
C=fog1
IP=192.168.0.11

kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.7/config/manifests/metallb-native.yaml
kubectl -n metallb-system wait --for=condition=Ready pod --all --timeout=180s
sed -e "s/<PUBLIC_IP_OF_THE_VM>/$IP/" -e "s/172\.18\.255\./10.201.255./g" \
  ~/MicroFog/Prototype_Setup/cluster-setup/$C/ip_pool_$C.yaml | kubectl apply -f -
kubectl -n metallb-system get ipaddresspools -o yaml | grep -A3 addresses    # 10.201.255.x e o $IP/32
```

O pool tem duas partes: uma faixa dentro da rede Docker `kind` (no original, `172.18.255.x`; aqui, `10.201.255.x`, porque mudamos a rede no 00) e o IP do PC (`/32`). O IP do PC vai para o east-west gateway (M2), e é ele que os outros clusters usam.

### 5. Guardar a configuração

`carga$` copie os arquivos de cada PC (ponto de retorno; veja o [README](../README.md#pontos-de-retorno)):

```bash
for h in fog1 fog2 cloud1; do mkdir -p ~/backup/$h && scp -r $h:clusters ~/backup/$h/; done
```

## O que observar

```bash
kubectl get nodes -o custom-columns=NOME:.metadata.name,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory
```

Compare o allocatable de cada nó com o alvo da tabela. É exatamente isso que o CE vai "ver".

Disco: os PCs usam HDD, e o etcd grava em disco (`fsync`) a cada escrita. Confira se ele reclama (questão em aberto A5):

```bash
kubectl -n kube-system logs etcd-fog1-control-plane | grep -c "slow fdatasync"
```

## Verifique seu entendimento

1. Rode `docker ps` no PC. Quantos containers você vê? Qual a relação com `kubectl get nodes`?
2. `kubectl top nodes` mostra o mesmo uso de CPU para todos os nós, ou um diferente para cada? Por quê, se todos compartilham o mesmo PC?
3. Mude o `system-reserved` de um worker (`nano ~/clusters/kind-fog1.yaml`), recrie o cluster (`kind delete cluster --name fog1 && kind create cluster --config ~/clusters/kind-fog1.yaml`) e confira o novo allocatable. Recriar apaga os passos 2–4, que precisam ser refeitos depois. Que impacto isso teria num placement do V1 (sem escalonamento horizontal)?
4. Por que os três clusters podem usar a mesma porta 15443 do host sem conflito? Isso funcionaria se estivessem num PC só?
5. Que experimento do artigo seria mais distorcido pelo *overcommit* de CPU: o da Fig. 11 (latência dos stores) ou o da Fig. 13 (tempo de placement)? Por quê?

## Problemas comuns

| Sintoma | Causa provável | Diagnóstico |
|---|---|---|
| `kind create` trava em "Starting control-plane" | Imagem antiga do nó incompatível com o kernel/cgroup do host | `docker logs fog1-control-plane`; é o caso NO-GO do portão |
| Pods em `CrashLoopBackOff` com "too many open files" | Limites de inotify | [00](00-preparar-pcs-e-rede.md), passo 7 |
| `kubectl top` → "metrics not available" | Falta `--kubelet-insecure-tls` ou ainda não houve coleta | `kubectl -n kube-system logs deploy/metrics-server` |
| Nó `NotReady` ou allocatable negativo | `system-reserved` maior que a capacidade do PC | `kubectl describe node`; refaça a conta com o `MemTotal` real |
| API server lento, `kubectl` com timeouts | etcd em HDD (`slow fdatasync`) | Logs do etcd; questão A5 em `decisoes.md` |

## Registro de execução

- Data:
- Resultado do portão: GO / NO-GO (erro):
- Versões usadas (kind, imagem do nó, Istio, MetalLB, metrics-server):
- `MemTotal` de cada PC e `system-reserved` finais por nó:
- Avisos `slow fdatasync` do etcd (quantidade em ~10 min):
- Desvios do plano:
