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

1. Apague as aplicações dos marcos anteriores (`kubectl delete ns hcapp app2` em todos os clusters).
2. Atualize os ConfigMaps conforme a tabela e reinicie os pods dos CEs. Comece pelos fogs e termine pelo cloud1.
3. Confirme que um fog recusa PRs:

   ```bash
   H='Host: control-engine.control-engine.svc.cluster.local'
   curl -s -H "$H" -H "cluster: fog1" -H 'Content-Type: application/json' \
        -d @pr-app2.json http://192.168.0.11/MicroFog/addPR
   ```

4. Submeta o mesmo PR ao **cloud1** (`cluster: cloud1`). Mantenha `entryClusters: ["fog1"]`: o placement começa pelo fog1, mesmo sendo decidido no cloud1.
5. Acompanhe os logs dos quatro CEs. No primário, procure `RETRIEVE_OTHER_CLUSTER_DATA_BEGIN/END` e `DEPLOY_COMMANDS_FORWARD`. Nos fogs, procure `DEPLOYMENT_OF_RECEIVED_COMMANDS_STARTED`.
6. Chame a aplicação como no M6, passo 4.

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
