# M6 — Placement distribuído

## Objetivo

Submeter um PR do **app2** ao fog1 com um throughput que **não cabe** no fog1. Observar o CE do fog1 colocar o que der, **encaminhar** o PR parcialmente atendido ao fog2 (e, se preciso, ao cloud1) e chegar a uma aplicação funcionando com microserviços em vários clusters.

## Conceitos

### V2: escalonamento horizontal distribuído (§6.1.3)

1. O CE recebe o PR e lê do Redis o DAG da aplicação.
2. Descobre o que **já foi colocado** (`placedMicroservices`) e qual é o próximo microserviço do DAG.
3. Calcula as instâncias necessárias: ⌈throughput ÷ throughput por instância⌉.
4. Coloca no próprio cluster o quanto couber, nó a nó.
5. Se faltar, **atualiza o PR** (o que foi colocado, em quais clusters já passou) e o **encaminha** a um cluster vizinho.

O V1 é igual, mas com uma única instância por microserviço, dimensionada para todo o throughput (escalonamento vertical). Por isso o V1 empurra o placement para a cloud mais cedo (Tabela 3, Fig. 17).

### Políticas de forwarding (§6.2.1)

`requestForwardingLogic/ForwardingPolicy.java`:

| Valor no ConfigMap | No artigo | Comportamento |
|---|---|---|
| `to_rand_fog` | FP1 | Um fog vizinho ainda não visitado, escolhido ao acaso; se não houver, a cloud |
| `to_cloud` | FP2 | Direto para uma cloud vizinha |

Os clusters já visitados ficam em `traversedClusters`, o que evita ciclos. O PR encaminhado é enviado para `controlengine.forwardUrl` (o Service único dos CEs) com o cabeçalho `cluster: <próximo>`, ou seja, pelo mesmo mecanismo do M4.

### A aplicação app2 (Fig. 15)

| Microserviço | CPU | Throughput/instância |
|---|---|---|
| a2m1 | 0,8 | 100 |
| a2m2 | 0,6 | 100 |
| a2m3 | 0,8 | 100 |
| a2m4 | 0,6 | 100 |

Um único serviço composto (`APP2_S1`): a2m1 → a2m2, e a2m2 agrega a2m3 e a2m4 antes de responder.

## Passos

### 1. Prever

Com throughput **200**: quantas instâncias de cada microserviço, e quanto de CPU no total (incluindo 0,1 de sidecar por pod)? Compare com o que está livre em cada cluster.

O filtro `jq` calcula a CPU livre de cada nó como o CE faz (`FogDevice.getRemainingCpu`): o total menos o maior valor entre o usado e o alocado.

`carga$` (pc-lamp-5):

```bash
H='Host: control-engine.control-engine.svc.cluster.local'
for c in fog1 fog2 cloud1; do
  echo "== $c"
  curl -s -H "$H" -H "cluster: $c" http://192.168.0.11/MicroFog/getClusterData \
    | jq -r '.fogDevices[] | "\(.nodeName)  total=\(.resourcesTotal.cpu)  livre=\(.resourcesTotal.cpu - ([.resourcesUsed.cpu, .resourcesAllocated.cpu] | max))"'
done
```

Escreva: o que fica no fog1, o que vai para o fog2 e o que (se algo) vai para o cloud1. Se pela sua conta tudo couber no fog1, aumente o throughput (300, 400...) até forçar o forwarding, e registre o valor usado.

### 2. Submeter ao fog1

Abra antes os três terminais do passo 3, para ver o PR chegando.

`carga$` (pc-lamp-5) grave o PR e envie-o. Se pela previsão você aumentou o throughput, troque o `200`:

```bash
cd ~
cat > pr-app2.json <<'EOF'
{"applicationId":"app2","placedMicroservices":[],"compositionOnlyPlacements":[],
 "entryClusters":["fog1"],
 "qosParameters":[{"qosLevel":"QoS App Level","identifier":"app2","parameter":"throughput","value":200}],
 "restrictions":[],"traversedClusters":[]}
EOF
curl -s -H "$H" -H "cluster: fog1" -H 'Content-Type: application/json' \
     -d @pr-app2.json http://192.168.0.11/MicroFog/addPR
```

### 3. Seguir o PR pelos três clusters

Abra três terminais, um em cada PC de cluster.

`fog1$` (pc-lamp-1):

```bash
kubectl -n control-engine logs -f controller-fog1 -c controller-fog1
```

`fog2$` (pc-lamp-2):

```bash
kubectl -n control-engine logs -f controller-fog2 -c controller-fog2
```

`cloud1$` (pc-lamp-3):

```bash
kubectl -n control-engine logs -f controller-cloud1 -c controller-cloud1
```

Procure `REQUEST_FORWARD` no fog1 e `NEW_PR_RECEIVED` logo depois no fog2. Os timestamps em milissegundos permitem medir quanto tempo o forwarding levou.

`clusters$` (pc-lamp-1 a 3) veja onde cada microserviço foi parar:

```bash
kubectl -n app2 get pods -o wide
kubectl -n app2 get svc,vs,dr
```

### 4. Chamar a aplicação

`carga$` (pc-lamp-5):

```bash
curl -s -H 'Host: a2m1.app2.svc.cluster.local' -H 'Content-Type: application/json' \
     -X GET http://192.168.0.11/DummyM/getResults -d '{"message":[65,68,67],"dataProcessingTime":30}'
```

A requisição entra no fog1, e cada chamada para um microserviço que está em outro cluster passa pelo east-west gateway do M2.

### 5. Trocar a política

Essa é a comparação FP1 × FP2 da Fig. 12.

`clusters$` (pc-lamp-1 a 3) apague o `app2` em todos os clusters:

```bash
kubectl delete ns app2
```

`fog1$` (pc-lamp-1) mude a política para `to_cloud`. O CE só lê o ConfigMap ao iniciar, e o pod não pertence a um Deployment, então é preciso apagá-lo e aplicá-lo de novo:

```bash
sed -i 's/forwardpolicy = to_rand_fog/forwardpolicy = to_cloud/' ~/ce/controller-configmap-fog1.yaml
grep forwardpolicy ~/ce/controller-configmap-fog1.yaml
kubectl -n control-engine apply -f ~/ce/controller-configmap-fog1.yaml
kubectl -n control-engine delete pod controller-fog1
kubectl -n control-engine apply -f ~/ce/controller-fog1.yaml
kubectl -n control-engine wait --for=condition=Ready pod/controller-fog1 --timeout=300s
```

Repita os passos 2–4. No fim, volte o fog1 para FP1 com os mesmos comandos, trocando `to_cloud` por `to_rand_fog` no `sed` (`s/forwardpolicy = to_cloud/forwardpolicy = to_rand_fog/`).

## O que observar

- Microserviços do mesmo app em clusters diferentes, e alguns microserviços com instâncias em **mais de um cluster** (escalonamento horizontal entre clusters).
- `traversedClusters` crescendo a cada forwarding (aparece no PR logado pelo CE).
- VS e DR criados pelo CE **em todos os clusters** envolvidos, inclusive em clusters sem nenhuma instância do microserviço (`compositionOnlyPlacements` / `deployedServiceLvlOnly`). Por que eles são necessários lá?

## Verifique seu entendimento

1. Por que o Service `a2m2` precisa existir num cluster que não tem nenhum pod a2m2?
2. Com FP2 (`to_cloud`), a latência do `curl` do passo 4 aumentou ou diminuiu em relação ao FP1? Isso bate com a Fig. 12? Com que ressalva (este marco roda sem WAN emulada; a lição da [WAN](wan-netem.md) refaz a comparação)?
3. Mude o fog1 para `controlengine.placementalgo.version = V1` (`sed -i -E 's/(placementalgo.version\s*=\s*)V2/\1V1/' ~/ce/controller-configmap-fog1.yaml` e os mesmos `apply`/`delete pod`/`apply` do passo 5) e repita com FP1. Compare com a Tabela 3: o placement vai mais para a cloud?
4. O que acontece se **nenhum** cluster tiver recursos? Leia `selectRandomCluster` com uma lista vazia.

## Problemas comuns

| Sintoma | Causa provável | Diagnóstico |
|---|---|---|
| Fica tudo no fog1, ou nada é implantado, sem forwarding | `forwardpolicy` não reconhecido (`to_fog_cloud`) | [M4](m4-control-engine.md), passo 2 |
| `REQUEST_FORWARD` no fog1, mas nada chega ao fog2 | VS do CE sem rota para `addPR` com `cluster: fog2` | M4, passo 1; log do sidecar do CE do fog1 |
| Erro ao buscar dados de outro cluster | `getClusterData` sem rota no VS original | M4, passo 5 |
| `IndexOutOfBoundsException` em `selectRandomCluster` | Nenhum cluster candidato restante | Os recursos acabaram: reduza o throughput |

## Registro de execução

- Data:
- Previsão × placement real (por cluster):
- Tempo de forwarding (fog1 → fog2):
- FP1 × FP2 (latência do curl, 10 repetições):
- Desvios do plano:
