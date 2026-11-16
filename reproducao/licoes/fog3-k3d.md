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

Use uma imagem `rancher/k3s` com a **mesma versão de Kubernetes** dos outros clusters, conforme o portão do M1. Uma versão de Kubernetes diferente entre os clusters mudaria o comportamento do kubelet e do allocatable, e a comparação da Fig. 14 deixaria de ser só k8s × k3s.

No caso GO, a imagem é `rancher/k3s:v1.24.17-k3s1`, e o k3d da mesma época é o `v5.4.6`. Com NO-GO, liste as imagens k3s da versão de Kubernetes do fallback (troque `v1.24` por ela) e use o k3d mais recente:

```bash
curl -s "https://registry.hub.docker.com/v2/repositories/rancher/k3s/tags?page_size=100&name=v1.24" \
  | jq -r '.results[].name' | sort -V | tail
```

`fog3$` instale o k3d. O `kubectl` e o `istioctl` já foram instalados no 00 e no M1:

```bash
K3D_VERSION=v5.4.6
curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | TAG=$K3D_VERSION bash
k3d version
```

### 2. Criar o cluster

Os `system-reserved` seguem a proposta × 0,5 do [M1](m1-clusters.md#tamanhos-lógicos-dos-nós-questão-em-aberto-a2): server 1,5 vCPU / 3 Gi, agents 1 vCPU / 2 Gi. Os valores abaixo supõem `MemTotal` = 15 360 Mi no PC4. Confira o valor real:

```bash
fog3$ awk '/MemTotal/ {printf "%d Mi\n", $2/1024}' /proc/meminfo
```

`fog3$` grave o comando de criação em `~/clusters/`, como os YAMLs do KinD no M1. Assim ele entra na cópia de segurança e o cluster pode ser recriado igual. Se o `MemTotal` for outro, corrija os valores de `memory=` (MemTotal − alvo − 100 Mi) com `nano ~/clusters/k3d-fog3.sh` antes de rodar:

```bash
mkdir -p ~/clusters
cat > ~/clusters/k3d-fog3.sh <<'EOF'
k3d cluster create fog3 \
  --image rancher/k3s:v1.24.17-k3s1 \
  --servers 1 --agents 2 \
  --k3s-arg "--disable=traefik@server:0" \
  --k3s-arg "--disable=servicelb@server:0" \
  --k3s-arg "--tls-san=192.168.0.14@server:0" \
  --k3s-arg "--kubelet-arg=system-reserved=cpu=2.5,memory=12188Mi@server:0" \
  --k3s-arg "--kubelet-arg=system-reserved=cpu=3,memory=13212Mi@agent:0" \
  --k3s-arg "--kubelet-arg=system-reserved=cpu=3,memory=13212Mi@agent:1" \
  -p "15443:32012@agent:0" -p "80:32022@agent:0" -p "6443:32032@agent:0" \
  --k3s-node-label "topology.kubernetes.io/region=fog@server:0;agent:*" \
  --k3s-node-label "topology.kubernetes.io/zone=fog3@server:0;agent:*" \
  --k3s-node-label "istioingress=enable@agent:0" \
  --k3s-node-label "istioeastwest=enable@agent:0"
EOF
bash ~/clusters/k3d-fog3.sh
```

A sintaxe das opções muda entre versões do k3d (por exemplo, `--k3s-node-label` versus `--k3s-arg "--node-label=..."`). Se o comando falhar, confira com `k3d cluster create --help`, corrija o `~/clusters/k3d-fog3.sh` e registre a versão que funcionou.

O mapeamento de portas usa os **mesmos nodePorts** dos arquivos do Istio do repositório (32012, 32022, 32032), para reaproveitar a configuração do fog1.

```bash
fog3$ kubectl get nodes -L topology.kubernetes.io/region,topology.kubernetes.io/zone
fog3$ kubectl get nodes -o custom-columns=NOME:.metadata.name,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory
```

### 3. metrics-server e MetalLB

O k3s já traz o metrics-server. Confira:

```bash
fog3$ kubectl top nodes       # aguarde ~1 min depois de criar o cluster
```

O MetalLB é instalado como no M1, passo 4, mas o pool é escrito aqui, porque o repositório não tem um para o fog3. Ele contém `192.168.0.14/32` e uma faixa da rede Docker que o k3d criou (`k3d-fog3`). Com as faixas do Docker do [00](00-preparar-pcs-e-rede.md), passo 6, ela fica em `10.200.x.0/24`.

`fog3$`:

```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.7/config/manifests/metallb-native.yaml
kubectl -n metallb-system wait --for=condition=Ready pod --all --timeout=180s

SUBNET=$(docker network inspect k3d-fog3 -f '{{(index .IPAM.Config 0).Subnet}}')
PREFIX=${SUBNET%.*}       # 10.200.1.0/24 → 10.200.1
echo "$SUBNET -> pool ${PREFIX}.200-${PREFIX}.250"

cat > ~/clusters/ip_pool_fog3.yaml <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: fog3-pool
  namespace: metallb-system
spec:
  addresses:
  - ${PREFIX}.200-${PREFIX}.250
  - 192.168.0.14/32
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: example
  namespace: metallb-system
EOF
kubectl apply -f ~/clusters/ip_pool_fog3.yaml
```

### 4. Istio

**CA.** O fog3 precisa de um certificado intermediário assinado pela mesma CA raiz do M2. Ela só existe no fog1 (`~/certs`), então o certificado é gerado lá e copiado:

```bash
fog1$ cd ~/certs && make -f $ISTIO/tools/certs/Makefile.selfsigned.mk fog3-cacerts
fog1$ scp -r ~/certs/fog3 fog3:~/certs-fog3
```

`fog3$` crie o secret `cacerts` antes de instalar o Istio, como no M2, passo 1:

```bash
D=~/certs-fog3
kubectl create namespace istio-system
kubectl -n istio-system create secret generic cacerts \
  --from-file=$D/ca-cert.pem --from-file=$D/ca-key.pem \
  --from-file=$D/root-cert.pem --from-file=$D/cert-chain.pem
kubectl label namespace istio-system topology.istio.io/network=network4
```

**Instalação.** O `istio-fog3.yaml` parte do arquivo do fog1, com `clusterName: k3d-fog3`, `network4` em todas as ocorrências e o IP do PC4. `fog3$`:

```bash
sed -e 's/kind-fog1/k3d-fog3/' -e 's/network1/network4/g' -e 's/<PUBLIC_IP_OF_THE_VM>/192.168.0.14/' \
  ~/MicroFog/Prototype_Setup/cluster-setup/fog1/istio-fog1.yaml > ~/clusters/istio-fog3.yaml
grep -n -E "clusterName|network|loadBalancerIP" ~/clusters/istio-fog3.yaml

$ISTIO/bin/istioctl install -y -f ~/clusters/istio-fog3.yaml \
  --set components.pilot.k8s.resources.requests.cpu=100m \
  --set components.pilot.k8s.resources.requests.memory=512Mi
kubectl -n istio-system get svc istio-eastwestgateway     # EXTERNAL-IP = 192.168.0.14

cd ~/MicroFog/Prototype_Setup/cluster-setup
kubectl -n istio-system apply -f istio-cross-gateway.yaml
kubectl -n istio-system apply -f apiserver-gateway.yaml -f apiserver-vs.yaml
```

**`meshNetworks`.** `clusters$` (os quatro, fog3 incluído) acrescente a `network4`. O comando substitui a lista inteira do M2, passo 4:

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
      network4:
        endpoints: [{fromRegistry: k3d-fog3}]
        gateways: [{address: 192.168.0.14, port: 15443}]
'
```

**Remote secrets.** O fog3 gera o seu e precisa dos três que os outros PCs geraram no M2, passo 5:

```bash
fog3$ cd ~ && $ISTIO/bin/istioctl x create-remote-secret --name=k3d-fog3 \
        --server=https://192.168.0.14:6443 > secret-fog3.yaml
```

Só o fog1, o fog2 e o cloud1 têm chave SSH para o fog3 (00, passo 4), então são eles que copiam nos dois sentidos. `fog1$`, `fog2$` e `cloud1$` (troque `C`):

```bash
C=fog1
scp ~/secret-$C.yaml fog3: && scp fog3:secret-fog3.yaml ~/
kubectl apply -f ~/secret-fog3.yaml
```

```bash
fog3$ kubectl apply -f ~/secret-fog1.yaml -f ~/secret-fog2.yaml -f ~/secret-cloud1.yaml
fog3$ kubectl -n istio-system get secrets -l istio/multiCluster=true     # três secrets
```

**Teste com o helloworld** (M2, passo 6), agora com uma instância no fog3:

```bash
fog3$ kubectl create ns sample && kubectl label ns sample istio-injection=enabled
fog3$ kubectl -n sample apply -f $ISTIO/samples/helloworld/helloworld.yaml -l service=helloworld
fog3$ kubectl -n sample apply -f $ISTIO/samples/helloworld/helloworld.yaml -l version=v2
fog1$ for i in $(seq 20); do
        kubectl -n sample exec deploy/sleep -c sleep -- curl -sS helloworld.sample:5000/hello
      done
```

Algumas respostas devem vir do pod do fog3 (compare o nome da instância com `fog3$ kubectl -n sample get pods`).

### 5. Data stores e CE

**Data stores.** O artigo (E1) mantém data stores em fog1, fog2 e cloud1. O fog3 acessa os stores **pela malha**. Mesmo sem uma instância local, ele precisa dos Services `minio` e `redis`, dos VS e das DR, para que o nome DNS resolva e o failover por localidade valha também para ele.

`fog3$` faça a cópia dos manifestos do M3, passo 0, e aplique só os Services e as regras:

```bash
mkdir -p ~/stores
cp -r ~/MicroFog/Prototype_Setup/minio-setup ~/MicroFog/Prototype_Setup/redis-setup ~/stores/
kubectl create ns control-engine
kubectl label ns control-engine istio-injection=enabled
cd ~/stores/minio-setup
kubectl -n control-engine apply -f minioService.yaml -f minio_vs.yaml -f minio_dr.yaml \
  -f minioManagementService_fog1.yaml -f minioManagementService_fog2.yaml -f minioManagementService_cloud1.yaml
cd ~/stores/redis-setup
kubectl -n control-engine apply -f redis-service.yaml -f redis-service-primary.yaml -f redis-vs.yaml -f redis-dr.yaml
```

**ConfigMap e pod do CE.** O repositório não tem arquivos do fog3; eles partem dos do fog2. O fog3 tem como vizinhos os outros dois fogs e o cloud1. `fog3$`:

```bash
SETUP=~/MicroFog/Prototype_Setup/control-engine-setup
mkdir -p ~/ce
sed -e 's/cluster.name = fog2/cluster.name = fog3/' \
    -e 's/fog.adjacent.cluster\[0\] = fog1/fog.adjacent.cluster[0] = fog1\n    fog.adjacent.cluster[1] = fog2/' \
    -e 's/forwardpolicy = to_fog_cloud/forwardpolicy = to_rand_fog/' \
    $SETUP/controller-configmap-fog2.yaml > ~/ce/controller-configmap-fog3.yaml
sed 's/fog2/fog3/g' $SETUP/controller-fog2.yaml > ~/ce/controller-fog3.yaml
~/set-images.sh local ~/ce/controller-fog3.yaml      # ou upstream, como nos outros clusters
grep -E "cluster\.name|adjacent|populatemetadata|forwardpolicy" ~/ce/controller-configmap-fog3.yaml
grep -E "name:|cluster:|image:" ~/ce/controller-fog3.yaml
```

**DR e VS do CE.** `clusters$` (os quatro) acrescente o subset `fog3` à `control-engine-dr` e a rota `cluster: fog3` ao `control-engine-vs` do M4. O fog3 ainda não tem esses arquivos; o fog1 os envia, antes de acrescentar o fog3 aos seus:

```bash
fog1$ scp ~/ce/controller-dr.yaml ~/ce/controller-vs.yaml fog3:ce/
```

Depois, nos quatro PCs:

```bash
cat >> ~/ce/controller-dr.yaml <<'EOF'
  - name: fog3
    labels:
      cluster: fog3
EOF
cat >> ~/ce/controller-vs.yaml <<'EOF'
  - match: [{headers: {cluster: {exact: fog3}}}]
    route: [{destination: {host: control-engine, port: {number: 8080}, subset: fog3}}]
EOF
kubectl -n control-engine apply -f ~/ce/controller-dr.yaml -f ~/ce/controller-vs.yaml
```

**Subir o CE do fog3**, com os mesmos comandos do M4, passo 3:

```bash
fog3$ cd ~/MicroFog/Prototype_Setup/control-engine-setup
fog3$ kubectl -n control-engine apply -f controller-service-account.yaml -f permission.yaml
fog3$ kubectl -n control-engine apply -f ~/ce/controller-configmap-fog3.yaml -f ~/ce/controller-fog3.yaml
fog3$ kubectl -n control-engine apply -f controller-service.yaml -f controller-gateway.yaml
fog3$ kubectl -n control-engine wait --for=condition=Ready pod/controller-fog3 --timeout=300s
```

**Vizinhos nos outros CEs.** O fog3 entra como mais um fog vizinho, no próximo índice livre de cada ConfigMap:

```bash
fog1$   sed -i '/fog.adjacent.cluster\[0\] = fog2/a\    fog.adjacent.cluster[1] = fog3' ~/ce/controller-configmap-fog1.yaml
fog2$   sed -i '/fog.adjacent.cluster\[0\] = fog1/a\    fog.adjacent.cluster[1] = fog3' ~/ce/controller-configmap-fog2.yaml
cloud1$ sed -i '/fog.adjacent.cluster\[1\] = fog2/a\    fog.adjacent.cluster[2] = fog3' ~/ce/controller-configmap-cloud1.yaml
```

`fog1$`, `fog2$` e `cloud1$` confira e reinicie o CE (troque `C`):

```bash
C=fog1
grep adjacent ~/ce/controller-configmap-$C.yaml
kubectl -n control-engine apply -f ~/ce/controller-configmap-$C.yaml
kubectl -n control-engine delete pod controller-$C
kubectl -n control-engine apply -f ~/ce/controller-$C.yaml
kubectl -n control-engine wait --for=condition=Ready pod/controller-$C --timeout=300s
```

## O que observar

- `carga$ curl -H "Host: control-engine.control-engine.svc.cluster.local" -H "cluster: fog3" http://192.168.0.11/MicroFog/home` responde "… - fog3".
- Um PR do hcApp com `entryClusters: ["fog3"]` submetido ao fog3: compare o tempo `NEW_PR_RECEIVED` → `PLACEMENT_COMPLETED` com o mesmo PR no fog1 (esboço do E4). Com o `hcapp` apagado em todos os clusters:

  ```bash
  fog3$  kubectl -n control-engine logs -f controller-fog3 -c controller-fog3 | grep -E "NEW_PR_RECEIVED|PLACEMENT_COMPLETED"
  carga$ cd ~ && sed 's/"cloud1"/"fog3"/' pr-hcapp.json > pr-hcapp-fog3.json
  carga$ curl -s -H "Host: control-engine.control-engine.svc.cluster.local" -H "cluster: fog3" \
           -H 'Content-Type: application/json' -d @pr-hcapp-fog3.json http://192.168.0.14/MicroFog/addPR
  ```

## Verifique seu entendimento

1. Liste os pods de sistema do fog3 e do fog1 (`fog3$ kubectl -n kube-system get pods` e `fog1$ kubectl -n kube-system get pods`). Quais componentes do k8s não existem no k3s?
2. Por que desativar o Traefik e o `servicelb` do k3s?
3. Quantos remote secrets existem na malha com 4 clusters? E com *n*?

## Registro de execução

- Data:
- Versões de k3d e da imagem k3s:
- Comando `k3d cluster create` que funcionou:
- Ajustes feitos nos outros clusters:
