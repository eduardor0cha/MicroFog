# M5 — Placement local

## Objetivo

Submeter um **Placement Request** do hcApp ao CE do **cloud1**, acompanhar todo o fluxo de processamento pelo log e chamar os dois serviços compostos da aplicação com sucesso.

Por que começar pelo cloud1 (D23): ele tem os maiores nós (4 vCPU / 7 GB lógicos cada), e o hcApp (0,5 + 1,0 + 1,0 CPU, mais os sidecars) cabe lá com folga. Começar por um placement que **não precisa** de forwarding deixa uma variável a menos. Depois, o passo 5 repete o PR com entrada no fog1, onde Istio, CE e data stores já ocupam parte dos nós. O forwarding é o M6.

## Conceitos

### A aplicação (§2.3.4, Fig. 2)

O hcApp (*smart healthcare*) tem 3 microserviços e 2 **serviços compostos**, ou seja, caminhos que o usuário pode chamar:

| Serviço composto | Caminho | Rota HTTP |
|---|---|---|
| `hcAPP_S1` | hcm1 → hcm2 → hcm1 (resposta) | `GET /DummyM/getResults` |
| `hcAPP_S2` | hcm1 → hcm3 | `POST /DummyM/addData` |

Os requisitos ficam em `ControlEngine/.../metadata/SmartHealthAppSetup.java`:

| Microserviço | CPU | RAM | Throughput por instância |
|---|---|---|---|
| `hcApp_m1` (hcm1) | 0,5 | 100 MiB | 100 req/s |
| `hcApp_m2` (hcm2) | 1,0 | … | 100 req/s |
| `hcApp_m3` (hcm3) | 1,0 | … | 100 req/s |

O CE também reserva recursos para o sidecar de cada pod (`istio.proxy.cpu = 0.1`, `istio.proxy.memory = 128` no `application.properties` do CE).

### O Placement Request (Fig. 8)

```json
{
  "applicationId": "hcApp",
  "placedMicroservices": [],
  "compositionOnlyPlacements": [],
  "entryClusters": ["cloud1"],
  "qosParameters": [
    {"qosLevel": "QoS App Level", "identifier": "hcApp", "parameter": "throughput", "value": 100}
  ],
  "restrictions": [],
  "traversedClusters": []
}
```

- `entryClusters`: onde o tráfego do usuário entra. O placement começa por ali.
- `throughput`: o V2 calcula o número de instâncias como ⌈throughput pedido ÷ throughput por instância⌉ (`DistributedPlacement.getInstancesToPlace`).
- `placedMicroservices` e `traversedClusters` começam vazios. São preenchidos **pelos CEs** quando o PR é encaminhado (M6).

**Atenção:** sem o parâmetro `throughput`, o V2 lança `NullPointerException` (`new BigDecimal(null)` em `getInstancesToPlace`).

### Fluxo de processamento (§3.4)

Os eventos aparecem no log do CE nesta ordem, cada um com um *timestamp* em milissegundos (`utils/Events.java`):

```
NEW_PR_RECEIVED → PR_PROCESSING_BEGIN → RETRIEVE_REDIS_DATA_BEGIN/END (metadados)
→ PLACEMENT_ALGO_START → PLACEMENT_ALGO_COMPLETED → DEPLOYMENT_STARTED
→ LOAD_YAML_FILE_BEGIN/COMPLETED (MinIO) → "Created pod/service ..." → PLACEMENT_COMPLETED
```

As diferenças entre esses timestamps são a matéria-prima das figuras do artigo (tempo até o deploy na Fig. 13–14, latência dos stores na Fig. 11).

## Passos

### 1. Prever

Os comandos `curl` desta lição saem do `carga`, como os de um usuário. Antes de submeter, consulte os recursos livres do cloud1.

`carga$`:

```bash
H='Host: control-engine.control-engine.svc.cluster.local'
curl -s -H "$H" -H "cluster: cloud1" http://192.168.0.13/MicroFog/getClusterData | jq
```

**Escreva a sua previsão**: em qual nó vai cada microserviço? (Os algoritmos estão em `placementlogic/DistributedPlacement.java`, ramo `V2`.)

### 2. Submeter

Antes, `cloud1$` guarde as chaves do Redis, para comparar depois do placement (passo 5):

```bash
kubectl -n control-engine exec redis -c redis -- redis-cli --scan | sort > ~/redis-antes.txt
```

`carga$` (o PR fica em `~/pr-hcapp.json`, reaproveitado nas próximas lições):

```bash
cd ~
cat > pr-hcapp.json <<'EOF'
{"applicationId":"hcApp","placedMicroservices":[],"compositionOnlyPlacements":[],
 "entryClusters":["cloud1"],
 "qosParameters":[{"qosLevel":"QoS App Level","identifier":"hcApp","parameter":"throughput","value":100}],
 "restrictions":[],"traversedClusters":[]}
EOF

curl -s -H "$H" -H "cluster: cloud1" -H 'Content-Type: application/json' \
     -d @pr-hcapp.json http://192.168.0.13/MicroFog/addPR
```

Esperado: `Placement Request Successfully Submitted`.

### 3. Acompanhar

Os dois comandos ficam rodando até `Ctrl+C`, então use **dois terminais** no cloud1. De preferência, abra-os antes do passo 2, para ver o fluxo desde o `NEW_PR_RECEIVED`:

```bash
cloud1$ kubectl -n control-engine logs -f controller-cloud1 -c controller-cloud1 | grep -E "[A-Z_]{6,} - [0-9]{13}|Created"
```

```bash
cloud1$ kubectl -n hcapp get pods -o wide -w
```

### 4. Chamar a aplicação

`carga$`:

```bash
# S1: hcm1 → hcm2
curl -s -H 'Host: hcm1.hcapp.svc.cluster.local' -H 'Content-Type: application/json' \
     -X GET http://192.168.0.13/DummyM/getResults -d '{"message":[65,68,67],"dataProcessingTime":30}'

# S2: hcm1 → hcm3
curl -s -H 'Host: hcm1.hcapp.svc.cluster.local' -H 'Content-Type: application/json' \
     -X POST http://192.168.0.13/DummyM/addData -d '{"message":[65,68,67],"dataProcessingTime":30}'
```

### 5. Limpar

Para repetir o experimento, apague o namespace da aplicação. O `delete ns` só volta quando todos os pods terminaram:

```bash
cloud1$ kubectl delete ns hcapp
```

Confira se o CE guarda algum estado do placement anterior, no Redis ou em memória, e anote o que encontrar. No Redis, compare as chaves com as de antes do PR (passo 2):

```bash
cloud1$ kubectl -n control-engine exec redis -c redis -- redis-cli --scan | sort > ~/redis-depois.txt
cloud1$ diff ~/redis-antes.txt ~/redis-depois.txt      # chaves criadas pelo placement
```

Em memória, procure campos estáticos e coleções nos controladores do CE:

```bash
grep -rn -E "static .*(Map|List|Set)<" ~/MicroFog/ControlEngine/src/main/java/com/microfog/controlengine/
```

### 6. Repetir com entrada no fog1

Com o `hcapp` apagado, mude `entryClusters` para `["fog1"]` e submeta **ao fog1**. Antes, consulte os recursos livres do fog1 e faça uma nova previsão: agora o cluster de entrada já roda Istio, CE e data stores.

`carga$`:

```bash
curl -s -H "$H" -H "cluster: fog1" http://192.168.0.11/MicroFog/getClusterData | jq
```

```bash
fog1$ kubectl -n hcapp get pods -o wide -w      # num terminal à parte
```

```bash
carga$ cd ~ && sed 's/"cloud1"/"fog1"/' pr-hcapp.json > pr-hcapp-fog1.json
carga$ curl -s -H "$H" -H "cluster: fog1" -H 'Content-Type: application/json' \
         -d @pr-hcapp-fog1.json http://192.168.0.11/MicroFog/addPR
```

Chame a aplicação pelo fog1:

```bash
carga$ curl -s -H 'Host: hcm1.hcapp.svc.cluster.local' -H 'Content-Type: application/json' \
         -X GET http://192.168.0.11/DummyM/getResults -d '{"message":[65,68,67],"dataProcessingTime":30}'
carga$ curl -s -H 'Host: hcm1.hcapp.svc.cluster.local' -H 'Content-Type: application/json' \
         -X POST http://192.168.0.11/DummyM/addData -d '{"message":[65,68,67],"dataProcessingTime":30}'
```

## O que observar

- O placement real bate com a sua previsão? Se não bateu, descubra por quê no código.
- `kubectl -n hcapp get pods -o yaml | grep -A3 resources` mostra que o CE **define os requests** de cada pod, mesmo que os YAMLs do MinIO não tenham `resources`.
- Veja como o pod é fixado no nó (`kubectl -n hcapp get pods -o yaml | grep -E -A2 "nodeName|nodeSelector"`). Isso explica como o CE pode usar o control-plane, como o `cloud1-control-node` da Tabela 3.
- Os tempos entre `NEW_PR_RECEIVED` e `PLACEMENT_COMPLETED`.

## Verifique seu entendimento

1. Submeta o mesmo PR com `throughput` = 250, com o `hcapp` apagado antes (`cloud1$ kubectl delete ns hcapp`; `carga$ sed 's/"value":100/"value":250/' ~/pr-hcapp.json > ~/pr-hcapp-250.json` e o `curl` do passo 2 com `-d @pr-hcapp-250.json`). Quantas instâncias de cada microserviço? Ainda cabe no cloud1?
2. Com throughput 100 e entrada no fog1 (passo 6), o hcApp coube todo no fog1? Se não coube, o que aconteceu com o resto? *(Esse é o assunto do M6.)*
3. Que parte do artigo descreve o que acabou de acontecer entre `PLACEMENT_ALGO_COMPLETED` e `PLACEMENT_COMPLETED`?

## Problemas comuns

| Sintoma | Causa provável | Diagnóstico |
|---|---|---|
| `One or more required Fields of the placement request missing` | `applicationId` vazio ou `entryClusters` vazio | Revise o JSON |
| `Operation not supported in Central Mode` | `controlengine.operationmode.primary = false` | ConfigMap |
| `NullPointerException` em `getInstancesToPlace` | PR sem `throughput` | Acrescente o parâmetro |
| Pods em `ErrImagePull` | Imagem errada no YAML do MinIO | `IMAGE_SOURCE` e upload do M3 |
| Pods sobem mas o curl dá 404 | Gateway/VS do hcApp não criados, ou `Host` errado | `kubectl -n hcapp get gw,vs` |
| Pod em `Error` lendo o ConfigMap | Namespace/ConfigMap embutidos na imagem não batem | M0, passo 3 |

## Registro de execução

- Data:
- Previsão × placement real (cloud1 e fog1):
- Tempo `NEW_PR_RECEIVED` → `PLACEMENT_COMPLETED`:
- Desvios do plano:
