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

Com throughput **200**: quantas instâncias de cada microserviço, e quanto de CPU no total (incluindo 0,1 de sidecar por pod)? Compare com o que está livre em cada cluster:

```bash
H='Host: control-engine.control-engine.svc.cluster.local'
for c in fog1 fog2 cloud1; do
  echo "== $c"
  curl -s -H "$H" -H "cluster: $c" http://<IP_FOG1>/MicroFog/getClusterData | jq '.'   # filtre os campos de CPU livre
done
```

Escreva: o que fica no fog1, o que vai para o fog2 e o que (se algo) vai para o cloud1.

### 2. Submeter ao fog1

```bash
cat > pr-app2.json <<'EOF'
{"applicationId":"app2","placedMicroservices":[],"compositionOnlyPlacements":[],
 "entryClusters":["fog1"],
 "qosParameters":[{"qosLevel":"QoS App Level","identifier":"app2","parameter":"throughput","value":200}],
 "restrictions":[],"traversedClusters":[]}
EOF
curl -s -H "$H" -H "cluster: fog1" -H 'Content-Type: application/json' \
     -d @pr-app2.json http://<IP_FOG1>/MicroFog/addPR
```

### 3. Seguir o PR pelos três clusters

Abra três terminais:

```bash
fog1$   kubectl -n control-engine logs -f controller-fog1   -c controller-fog1
fog2$   kubectl -n control-engine logs -f controller-fog2   -c controller-fog2
cloud1$ kubectl -n control-engine logs -f controller-cloud1 -c controller-cloud1
```

Procure `REQUEST_FORWARD` no fog1 e `NEW_PR_RECEIVED` logo depois no fog2. Os timestamps em milissegundos permitem medir quanto tempo o forwarding levou.

```bash
todas$ kubectl -n app2 get pods -o wide
todas$ kubectl -n app2 get svc,vs,dr
```

### 4. Chamar a aplicação

```bash
curl -s -H 'Host: a2m1.app2.svc.cluster.local' -H 'Content-Type: application/json' \
     -X GET http://<IP_FOG1>/DummyM/getResults -d '{"message":[65,68,67],"dataProcessingTime":30}'
```

A requisição entra no fog1, e cada chamada para um microserviço que está em outro cluster passa pelo east-west gateway do M2.

### 5. Trocar a política

Apague o `app2` em todos os clusters (`kubectl delete ns app2`). Mude o fog1 para `controlengine.forwardpolicy = to_cloud`. Para o CE ler o ConfigMap novo, reinicie o pod (`kubectl delete pod controller-fog1` e aplique de novo). Repita os passos 2–4. Essa é a comparação FP1 × FP2 da Fig. 12.

## O que observar

- Microserviços do mesmo app em clusters diferentes, e alguns microserviços com instâncias em **mais de um cluster** (escalonamento horizontal entre clusters).
- `traversedClusters` crescendo a cada forwarding (aparece no PR logado pelo CE).
- VS e DR criados pelo CE **em todos os clusters** envolvidos, inclusive em clusters sem nenhuma instância do microserviço (`compositionOnlyPlacements` / `deployedServiceLvlOnly`). Por que eles são necessários lá?

## Verifique seu entendimento

1. Por que o Service `a2m2` precisa existir num cluster que não tem nenhum pod a2m2?
2. Com FP2 (`to_cloud`), a latência do `curl` do passo 4 aumentou ou diminuiu em relação ao FP1? Isso bate com a Fig. 12? Com que ressalva (na Fase A não há WAN emulada)?
3. Mude o fog1 para `controlengine.placementalgo.version = V1` e repita com FP1. Compare com a Tabela 3: o placement vai mais para a cloud?
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
