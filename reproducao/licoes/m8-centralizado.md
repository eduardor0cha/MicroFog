# M8 — Modo centralizado

## Objetivo

Reconfigurar os CEs para o **modo centralizado**: só o CE do cloud1 (primário) recebe PRs e executa o placement **V3**, com uma visão de todos os clusters. Ele envia a cada cluster a parte do placement que lhe cabe, e os CEs dos fogs só implantam.

## Conceitos

### Distribuído × centralizado (§3.3.1, Fig. 4, Fig. 13)

| | Distribuído (M6) | Centralizado (aqui) |
|---|---|---|
| Quem recebe PRs | O CE do cluster de entrada | Só o CE primário |
| Quem decide | Cada CE, sobre o próprio cluster, encaminhando o resto | O primário, sobre todos os clusters |
| Visão dos recursos | Local | Global (API 2, `getClusterData`, em cada cluster) |
| Como o placement chega aos clusters | Cada CE implanta o que decidiu | O primário chama a API 3 (`submitDeploymentInfo`) em cada cluster |
| Algoritmo | V1 / V2 | V3 |

Na Fig. 13, o modo distribuído escala melhor com mais PRs e mais clusters, porque todos os CEs dividem o trabalho. Em `controllers/PlacementLogicExecutor.java`, o caminho centralizado é o das condições `!distributedPlacement && isPrimaryCE` (linhas 123 e 438).

### Configuração

| Propriedade | cloud1 (primário) | fogs |
|---|---|---|
| `controlengine.operationmode.distributed` | `false` | `false` |
| `controlengine.operationmode.primary` | `true` | `false` |
| `controlengine.placementalgo.version` | `V3` | (não usado) |
| `controlengine.loadblancing.enabled` | `false`: o V3 não escalona horizontalmente (comentário em `DistributedPlacement.java`) | `false` |
| `fog.adjacent.cluster[...]` / `cloud.adjacent.cluster[...]` | **todos** os clusters que o primário administra | — |

Com `primary = false`, o `addPR` responde `Operation not supported in Central Mode` (`services/Services.java`).

## Passos

### 1. Apagar as aplicações

Apague as aplicações dos marcos anteriores. O `--ignore-not-found` evita erro onde o namespace não existe:

```bash
clusters$ kubectl delete ns hcapp app2 --ignore-not-found
```

### 2. Guardar os ConfigMaps do modo distribuído

Os ConfigMaps do M4–M6 voltam a ser usados depois. `clusters$` (troque `C` conforme o PC: `fog1`, `fog2`, `fog3` ou `cloud1`):

```bash
C=fog1
cp ~/ce/controller-configmap-$C.yaml ~/ce/controller-configmap-$C-distribuido.yaml
```

### 3. Atualizar os ConfigMaps

`fog1$`, `fog2$` e `fog3$`: modo centralizado, sem aceitar PRs e sem load balancing:

```bash
C=fog1
F=~/ce/controller-configmap-$C.yaml
sed -i -E 's/(operationmode\.distributed\s*=\s*)true/\1false/;
           s/(operationmode\.primary\s*=\s*)true/\1false/;
           s/(loadblancing\.enabled\s*=\s*)true/\1false/' $F
grep -E "operationmode|loadblancing.enabled" $F
```

`cloud1$`: primário, com o V3, sem load balancing, e com **todos** os fogs como vizinhos. Depois do [fog3](fog3-k3d.md), o ConfigMap do cloud1 já lista `fog1`, `fog2` e `fog3`:

```bash
F=~/ce/controller-configmap-cloud1.yaml
sed -i -E 's/(operationmode\.distributed\s*=\s*)true/\1false/;
           s/(placementalgo\.version\s*=\s*)V2/\1V3/;
           s/(loadblancing\.enabled\s*=\s*)true/\1false/' $F
grep -E "operationmode|placementalgo.version|loadblancing.enabled|adjacent" $F
```

Confira na saída que os valores batem com a tabela de configuração acima.

### 4. Reiniciar os CEs

O CE só lê o ConfigMap ao iniciar. Comece pelos fogs e termine pelo cloud1, para que o primário já encontre os outros CEs no modo novo.

`fog1$`, `fog2$` e `fog3$`, depois `cloud1$` (troque `C`):

```bash
C=fog1
kubectl -n control-engine apply -f ~/ce/controller-configmap-$C.yaml
kubectl -n control-engine delete pod controller-$C
kubectl -n control-engine apply -f ~/ce/controller-$C.yaml
kubectl -n control-engine wait --for=condition=Ready pod/controller-$C --timeout=300s
```

### 5. Confirmar que um fog recusa PRs

`carga$`:

```bash
H='Host: control-engine.control-engine.svc.cluster.local'
curl -s -H "$H" -H "cluster: fog1" -H 'Content-Type: application/json' \
     -d @$HOME/pr-app2.json http://192.168.0.11/MicroFog/addPR
```

Esperado: `Operation not supported in Central Mode`.

### 6. Submeter ao cloud1

Abra antes os logs dos quatro CEs, um terminal por PC (`Ctrl+C` encerra):

```bash
fog1$   kubectl -n control-engine logs -f controller-fog1   -c controller-fog1
fog2$   kubectl -n control-engine logs -f controller-fog2   -c controller-fog2
fog3$   kubectl -n control-engine logs -f controller-fog3   -c controller-fog3
cloud1$ kubectl -n control-engine logs -f controller-cloud1 -c controller-cloud1
```

`carga$` submeta o mesmo PR ao **cloud1**. Mantenha `entryClusters: ["fog1"]`: o placement começa pelo fog1, mesmo sendo decidido no cloud1:

```bash
curl -s -H "$H" -H "cluster: cloud1" -H 'Content-Type: application/json' \
     -d @$HOME/pr-app2.json http://192.168.0.11/MicroFog/addPR
```

No primário, procure `RETRIEVE_OTHER_CLUSTER_DATA_BEGIN/END` e `DEPLOY_COMMANDS_FORWARD`. Nos fogs, procure `DEPLOYMENT_OF_RECEIVED_COMMANDS_STARTED`.

### 7. Chamar a aplicação

`carga$`:

```bash
curl -s -H 'Host: a2m1.app2.svc.cluster.local' -H 'Content-Type: application/json' \
     -X GET http://192.168.0.11/DummyM/getResults -d '{"message":[65,68,67],"dataProcessingTime":30}'
```

### 8. Voltar ao modo distribuído

`clusters$` restaure os ConfigMaps do passo 2 e reinicie os CEs como no passo 4, de novo com os fogs primeiro:

```bash
C=fog1
cp ~/ce/controller-configmap-$C-distribuido.yaml ~/ce/controller-configmap-$C.yaml
```

## O que observar

- O tempo entre `NEW_PR_RECEIVED` (cloud1) e a criação dos pods nos fogs, agora atravessando a WAN emulada duas vezes: para buscar os dados e para enviar os comandos.
- Compare com o mesmo PR no modo distribuído (M6). Que modo foi mais rápido para **um** PR? E para 5 PRs simultâneos? (esboço do E3)

## Verifique seu entendimento

1. Por que o V3 não serve para o modo distribuído, e o V2 não serve para o centralizado (§6.1.3)?
2. Se o cloud1 cair no modo centralizado, o que para de funcionar? E no distribuído?
3. Num ambiente com 50 fogs, qual modo você escolheria, e com que modo de placement (periódico ou event-driven)?

## Registro de execução

- Data:
- ConfigMaps usados:
- Tempo de placement: centralizado × distribuído (mesmo PR):
