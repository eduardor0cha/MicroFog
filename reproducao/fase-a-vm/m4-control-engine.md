# M4 — Control Engine

## Objetivo

O MicroFog-CE rodando nos três clusters em **modo distribuído**, com:
- o CE do cloud1 tendo gravado os metadados das aplicações no Redis;
- cada CE respondendo às três APIs, tanto **localmente** quanto quando chamado **a partir de outro cluster**, com o roteamento pelo cabeçalho `cluster` da Fig. 7.

## Conceitos

### As três APIs (Fig. 8–10)

Todas ficam sob `/MicroFog` (`ControlEngine/src/main/java/com/microfog/controlengine/services/Services.java`) e recebem o cabeçalho HTTP `cluster` com o nome do cluster de destino:

| API | Método e caminho | Uso |
|---|---|---|
| — | `GET /MicroFog/home` | Teste: "Hello from MicroFog Scheduler - fog1" |
| 1 | `POST /MicroFog/addPR` | Submeter um PR (usuário, ou outro CE no forwarding) |
| 2 | `GET /MicroFog/getClusterData` | Recursos dos nós deste cluster (usado por outros CEs) |
| 3 | `POST /MicroFog/submitDeploymentInfo` | Receber a saída de um placement para implantar aqui |

### Um nome, vários CEs (§4.3, Fig. 7)

Todos os CEs estão atrás do **mesmo** Service, `control-engine.control-engine.svc.cluster.local:8080`, que existe nos três clusters. Para alcançar o CE de um cluster específico, o chamador põe `cluster: fog2` no cabeçalho, e o Istio faz o resto:
- a **DestinationRule** `control-engine-dr` define um *subset* por cluster (pods com o rótulo `cluster: fog2`);
- o **VirtualService** `control-engine-vs` manda cada valor do cabeçalho para o subset correspondente.

Por isso o CE só precisa de uma URL de configuração (`controlengine.forwardUrl`) para falar com qualquer outro.

### Modos de operação (§3.3.1, Fig. 4)

No `controller-configmap-<cluster>.yaml`:

```properties
controlengine.operationmode.distributed = true   # cada CE executa o placement
controlengine.operationmode.primary     = true   # este CE aceita PRs (addPR)
controlengine.placementmode.periodic    = false  # event-driven: processa assim que o PR chega
controlengine.placementalgo         = DISTRIBUTED_PLACEMENT
controlengine.placementalgo.version = V2         # escalonamento horizontal (§6.1.3)
controlengine.forwardpolicy = to_rand_fog        # FP1: fog adjacente (aleatório), depois cloud. FP2 = to_cloud
fog.adjacent.cluster[0]   = fog2                 # vizinhos deste cluster
cloud.adjacent.cluster[0] = cloud1
controlengine.loadblancing.policy = weighted_round_robin
```

O modo centralizado fica para o [M8](../fase-b-pcs/m8-centralizado.md).

## Passos

### 1. Revisar o VirtualService do CE

O `Prototype_Setup/control-engine-setup/controller-vs.yaml` tem rotas para `/MicroFog/home`, `/addPR`, `/executeCommands` e `/getDeviceData`. Mas o código do CE neste repositório usa `/getClusterData` e `/submitDeploymentInfo` para as APIs 2 e 3 (`controllers/PlacementLogicExecutor.java:214` e `:443`). Sem rota, o Envoy responde **404** a essas chamadas entre clusters.

Hipótese: a imagem `samodha/microfog:latest` foi construída de uma versão do código com os nomes antigos, e o VS acompanhou aquela versão. **Teste** essa hipótese no passo 5, em vez de assumi-la.

Crie `~/ce/controller-vs.yaml` roteando **só pelo cabeçalho**, o que vale para qualquer caminho:

```yaml
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: control-engine-vs
spec:
  hosts:
  - "control-engine.control-engine.svc.cluster.local"
  gateways:
  - control-engine-gw
  - mesh
  http:
  - match: [{headers: {cluster: {exact: fog1}}}]
    route: [{destination: {host: control-engine, port: {number: 8080}, subset: fog1}}]
  - match: [{headers: {cluster: {exact: fog2}}}]
    route: [{destination: {host: control-engine, port: {number: 8080}, subset: fog2}}]
  - match: [{headers: {cluster: {exact: cloud1}}}]
    route: [{destination: {host: control-engine, port: {number: 8080}, subset: cloud1}}]
```

### 2. Revisar os ConfigMaps

Copie `controller-configmap-<cluster>.yaml` para `~/ce/` e confira, em cada um:
- `cluster.name` igual ao nome do cluster;
- vizinhos (`fog.adjacent.cluster[...]`, `cloud.adjacent.cluster[...]`) coerentes com a topologia de 3 clusters;
- só o **cloud1** com `controlengine.populatemetadata = true`;
- `controlengine.forwardpolicy` com um valor que o código **reconhece**. `requestForwardingLogic/ForwardingPolicy.java` só aceita `to_rand_fog` (FP1) e `to_cloud` (FP2). Os ConfigMaps do fog1 e do fog2 trazem `to_fog_cloud`, que cai no `default` do `switch` e devolve `null`: o PR nunca seria encaminhado. Use **`to_rand_fog`** (é a mesma hipótese de diferença de versão entre imagem e código do passo 1);
- `minio.*` e `redis.url` apontando para os nomes internos do M3.

Ajuste a imagem do `controller-<cluster>.yaml` conforme `IMAGE_SOURCE` e troque `imagePullPolicy` para `IfNotPresent`.

### 3. Implantar: cloud1 primeiro

O CE do cloud1 **lê os YAMLs do MinIO e grava os metadados no Redis** ao iniciar (`metadata/MeteDataGenerator.java`). Por isso, ele sobe primeiro, depois do M3 completo.

`todas$` (troque `cloud1` pelo cluster da VM):

```bash
cd ~/MicroFog/Prototype_Setup/control-engine-setup
N=control-engine
kubectl -n $N apply -f controller-service-account.yaml -f permission.yaml
kubectl -n $N apply -f ~/ce/controller-configmap-cloud1.yaml
kubectl -n $N apply -f ~/ce/controller-cloud1.yaml
kubectl -n $N apply -f controller-service.yaml -f controller-gateway.yaml -f controller-dr.yaml
kubectl -n $N apply -f ~/ce/controller-vs.yaml
kubectl -n $N logs -f controller-cloud1 -c controller-cloud1
```

`permission.yaml` dá ao CE acesso total ao cluster (`ClusterRole` com `*`). Isso é aceitável num laboratório isolado, não em produção.

Confira os metadados:

```bash
cloud1$ kubectl -n control-engine exec redis -c redis -- redis-cli --scan | head
```

Depois repita os comandos no fog1 e no fog2.

### 4. Testes locais e entre clusters

O gateway do CE (`controller-gateway.yaml`) só aceita o host `control-engine.control-engine.svc.cluster.local`, por isso o cabeçalho `Host`:

```bash
H='Host: control-engine.control-engine.svc.cluster.local'

# Local: entrar pelo fog1 e falar com o CE do fog1
curl -s -H "$H" -H "cluster: fog1" http://<IP_FOG1>/MicroFog/home

# Entre clusters: entrar pelo fog1 e falar com o CE do fog2
curl -s -H "$H" -H "cluster: fog2" http://<IP_FOG1>/MicroFog/home

# API 2 no cloud1, chamada a partir do fog1
curl -s -H "$H" -H "cluster: cloud1" http://<IP_FOG1>/MicroFog/getClusterData | jq
```

### 5. Experimento: o VS original

Aplique temporariamente o `controller-vs.yaml` **original** e repita a última chamada (`getClusterData`):
- Com `IMAGE_SOURCE=local`: espera-se **404**. Confirme no log do sidecar (`kubectl logs <pod> -c istio-proxy`, procure `NR`, "no route").
- Com `IMAGE_SOURCE=upstream`: se a hipótese do passo 1 estiver certa, a imagem antiga responde em `/getDeviceData`. Teste `curl ... /MicroFog/getDeviceData`.

Volte para o VS do passo 1 e registre o resultado. Ele decide se o VS adaptado precisa ir para a Fase B.

## O que observar

- `"Hello from MicroFog Scheduler - fog2"` vindo de uma requisição que **entrou pelo fog1**: é a Fig. 7 funcionando.
- No `getClusterData`, a lista de nós com CPU/memória totais (allocatable), alocadas e usadas. Compare com `kubectl get nodes` e `kubectl top nodes` no cluster de destino.
- No log do CE, o evento `STARTED` e as configurações carregadas.

## Verifique seu entendimento

1. Mande `cluster: fog3` (um cluster inexistente). O que o Envoy responde e por quê?
2. Nos nós do `getClusterData`, quanto já está **alocado** antes de qualquer aplicação? Quem são esses pods? Que impacto isso tem no espaço livre para o hcApp?
3. Por que o CE do cloud1 é o único com `populatemetadata = true`? O que aconteceria se os três tivessem `true`?
4. `controlengine.placementmode.periodic = false` significa event-driven. Que vantagem o modo periódico com processamento em lote (§3.3.1) teria se chegassem 10 PRs ao mesmo tempo?

## Problemas comuns

| Sintoma | Causa provável | Diagnóstico |
|---|---|---|
| CE do cloud1 em `CrashLoopBackOff` no início | MinIO sem os YAMLs ou credenciais erradas | Log do CE: exceções do cliente MinIO |
| CE não lê o ConfigMap | Falta o ServiceAccount, a permissão ou o nome `controller-config` | `kubectl -n control-engine get cm,sa` |
| `404` do Envoy | VS sem rota para o caminho/cabeçalho | Passo 5 |
| `Error with roting : PR received by ...` | O cabeçalho `cluster` não chegou ao CE certo | DR com subsets e rótulo `cluster:` no pod |

## Registro de execução

- Data:
- `IMAGE_SOURCE` usado:
- Resultado do experimento do passo 5:
- Ajustes nos ConfigMaps:
- Desvios do plano:
