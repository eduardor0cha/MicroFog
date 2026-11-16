# M9 — Failover dos data stores

## Objetivo

Provocar a indisponibilidade dos data stores do fog1, depois também dos do fog2, e observar o CE do fog1 continuar funcionando: primeiro usando os stores do fog2 (**failover entre fogs**) e depois os do cloud1 (**failover para a cloud**). É a base qualitativa do experimento E1 (Fig. 11).

## Conceitos

Revise o [M3](m3-data-stores.md#arquitetura-distribuída-41-42-fig-6): os Services `minio` e `redis` têm endpoints nos três clusters, e a DestinationRule com `localityLbSetting` prioriza mesma zona → mesma região (`fog`) → `cloud`. O `outlierDetection` (1 erro 5xx → ejeção) é o que **ativa** o failover: sem ele, o Istio não sabe que a instância local está ruim.

| Cenário (Fig. 11) | Stores disponíveis | O CE do fog1 deve usar |
|---|---|---|
| 1 | fog1, fog2, cloud1 | fog1 (local) |
| 2 — "FO to Fog" | fog2, cloud1 | fog2 |
| 3 — "FO to Cloud" | cloud1 | cloud1 |

Para o Redis, lembre-se: as réplicas dos fogs são somente leitura, e o primário está no cloud1.

## Passos

Faça com a WAN emulada ativa: é ela que torna o cenário 3 visivelmente mais lento.

Os CEs precisam estar no modo distribuído (o [M8](m8-centralizado.md), passo 8, volta a ele).

Cada repetição usa o mesmo PR do hcApp com entrada no fog1, do [M5](m5-placement-local.md), passo 6 (`~/pr-hcapp-fog1.json` no `carga`).

Deixe o log do CE do fog1 aberto num terminal, filtrado pelos eventos que interessam:

```bash
fog1$ kubectl -n control-engine logs -f controller-fog1 -c controller-fog1 \
        | grep -E "RETRIEVE_REDIS_DATA_(BEGIN|END)|LOAD_YAML_FILE_(BEGIN|COMPLETED)"
```

Cada repetição apaga o `hcapp` e submete o PR. `carga$`:

```bash
ssh fog1 kubectl delete ns hcapp --ignore-not-found
ssh fog2 kubectl delete ns hcapp --ignore-not-found
ssh cloud1 kubectl delete ns hcapp --ignore-not-found
ssh fog3 kubectl delete ns hcapp --ignore-not-found
H='Host: control-engine.control-engine.svc.cluster.local'
curl -s -H "$H" -H "cluster: fog1" -H 'Content-Type: application/json' \
     -d @$HOME/pr-hcapp-fog1.json http://192.168.0.11/MicroFog/addPR
```

Os intervalos são a diferença entre os timestamps em milissegundos de `BEGIN` e `END`/`COMPLETED`.

1. **Cenário 1.** Faça a repetição com tudo no ar e anote os intervalos `RETRIEVE_REDIS_DATA_BEGIN → END` e `LOAD_YAML_FILE_BEGIN → COMPLETED`.
2. **Cenário 2.** Derrube os stores do fog1. Eles são Pods "soltos", não Deployments, então nada os recria sozinho. Os manifestos para recriá-los estão em `~/stores/` (M3):

   ```bash
   fog1$ kubectl -n control-engine delete pod minio-fog1 redis-replica
   ```

   Repita o PR e anote os mesmos intervalos.
3. **Cenário 3.** Derrube também os do fog2 e repita:

   ```bash
   fog2$ kubectl -n control-engine delete pod minio-fog2 redis-replica
   ```

4. Restaure tudo e confirme que o CE volta a usar o store local. O MinIO guarda os dados num `hostPath` do nó KinD, que sobrevive à remoção do pod, então o bucket deve continuar lá:

   ```bash
   fog1$ kubectl -n control-engine apply -f ~/stores/minio-setup/minio_fog1.yaml -f ~/stores/redis-setup/redis-replica.yaml
   fog2$ kubectl -n control-engine apply -f ~/stores/minio-setup/minio_fog2.yaml -f ~/stores/redis-setup/redis-replica.yaml
   ```

   Com o port-forward do M3, passo 2, ativo, confira os arquivos (`fog1$ mc ls fog1/microfog-app-metadata/hcApp/`). Se a lista vier vazia, porque o pod voltou num nó diferente, refaça no fog1 e no fog2 o passo 3 do M3 (bucket, versionamento e replicação): a opção `existing-objects` traz os arquivos de volta dos outros servidores.

Para ver **para onde** o tráfego foi, além do tempo:

```bash
fog1$ istioctl proxy-config endpoints controller-fog1.control-engine \
        --cluster "outbound|9000||minio.control-engine.svc.cluster.local"
```

A coluna de status mostra os endpoints ejetados (`UNHEALTHY`/outlier) e os ativos.

## O que observar

- Os intervalos crescem do cenário 1 para o 2 (pouco, porque a LAN entre fogs é rápida) e do 2 para o 3 (muito, por causa da WAN). Essa é a ordem da Fig. 11.
- A primeira requisição depois de derrubar um store pode falhar ou demorar mais: é o `outlierDetection` aprendendo. Como isso afeta uma medição?

## Verifique seu entendimento

1. O que aconteceria no cenário 2 se a DR não tivesse `outlierDetection`?
2. Por que a regra de failover é `from: fog, to: cloud`, e não uma lista explícita de clusters?
3. A §6.2.1 sugere hospedar os stores só em fogs ricos em recursos ou na cloud. Como você configuraria isso com os mesmos arquivos?

## Registro de execução

- Data:
- Intervalos por cenário (Redis e MinIO, n repetições):
- A ordem bate com a Fig. 11?
