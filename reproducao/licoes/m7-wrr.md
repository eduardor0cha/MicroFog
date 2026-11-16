# M7 — Weighted Round Robin entre clusters

## Objetivo

Confirmar que o tráfego de um microserviço com várias instâncias espalhadas entre clusters se divide **na proporção dos recursos alocados** a cada instância, como mostram as Fig. 15–16 do artigo. A verificação é feita de dois jeitos: visualmente no **Kiali** e contando as requisições por instância.

Com este marco, cada mecanismo central do MicroFog terá rodado pelo menos uma vez. As lições seguintes completam a arquitetura do artigo.

## Conceitos

### Load balancing no MicroFog (§6.2.2)

Quando o V2 coloca várias instâncias de um microserviço, a política de load balancing (`loadBalancing/LoadBalancingPolicies.java`, ativada por `controlengine.loadblancing.policy = weighted_round_robin`) calcula um **peso** por instância. O CE então gera:
- uma **DestinationRule** com um *subset* por grupo de instâncias;
- um **VirtualService** com `weight` por subset.

Exemplo do artigo (Tabela 3): a2m2 com três instâncias em `fog1-worker3`, `fog2-worker1` e `fog2-worker2`, recursos na proporção 1:2:1. O Kiali mostrou 1:3 entre os dois clusters e 2:1 dentro do fog2, o que dá ~1:2:1 entre as instâncias.

### Prometheus e Kiali (§3.3.3, §4.4)

- **Prometheus** coleta as métricas que os sidecars Envoy expõem (requisições, latência, erros).
- **Kiali** lê essas métricas e desenha o grafo de tráfego da malha.

## Passos

### 1. Instalar os addons

`clusters$` (os addons vêm na distribuição do Istio):

```bash
kubectl apply -f $ISTIO/samples/addons/prometheus.yaml
kubectl apply -f $ISTIO/samples/addons/kiali.yaml
kubectl -n istio-system rollout status deploy/kiali
```

O repositório também traz `kiali-setup/*.yaml` para expor o Kiali pelo ingress, mas a porta 80 já é disputada pelo CE e pelas aplicações. Por isso, use um port-forward. O `--address 0.0.0.0` deixa a porta aberta para os outros computadores do switch, e não só para o próprio PC. O comando ocupa o terminal até `Ctrl+C`:

```bash
fog1$ kubectl -n istio-system port-forward --address 0.0.0.0 svc/kiali 20001:20001
```

Abra `http://192.168.0.11:20001` no navegador de um computador ligado ao switch. Os PCs rodam Ubuntu Server, sem navegador.

Esta é uma instalação de Kiali **por cluster**: cada um mostra o tráfego visto pelos seus sidecars. A visão unificada multi-cluster (<https://kiali.io/docs/features/multi-cluster/>) fica como extensão.

### 2. Ler os pesos que o CE gerou

Com o app2 do M6 implantado:

```bash
clusters$ kubectl -n app2 get dr,vs -o yaml | grep -E -A3 "subsets:|weight:"
```

Anote os pesos esperados por instância/cluster.

### 3. Gerar carga

A carga sai do PC `carga`, para não roubar CPU dos clusters medidos.

```bash
carga$ hey -n 600 -c 4 -m GET \
    -H 'Host: a2m1.app2.svc.cluster.local' -H 'Content-Type: application/json' \
    -d '{"message":[65,68,67],"dataProcessingTime":30}' \
    http://192.168.0.11/DummyM/getResults
```

### 4. Contar as requisições por instância

Cada microserviço de teste registra `Request received for processing` a cada requisição. Em cada cluster que tem instâncias do a2m2:

```bash
clusters$ for p in $(kubectl -n app2 get pods -o name | grep a2m2); do
         # sem -c: a injeção do Istio marca o container da aplicação como padrão
         echo "$p $(kubectl -n app2 logs $p --since=10m | grep -c 'Request received for processing')"
       done
```

Compare as contagens com os pesos do passo 2.

### 5. Ver no Kiali

*Graph → Namespace app2 → Versioned app graph*, com *Display → Traffic distribution* ligado. Faça uma captura de tela parecida com a Fig. 15.

### 6. Guardar a configuração

`carga$` copie `~/clusters`, `~/ce`, `~/stores` e `~/certs*` de cada PC, como no M1, passo 5:

```bash
for h in fog1 fog2 cloud1; do
  mkdir -p ~/backup/$h
  scp -r "$h:clusters" "$h:ce" "$h:stores" "$h:certs*" ~/backup/$h/
done
```

## O que observar

- As contagens do passo 4 seguem os pesos do passo 2, dentro de alguns por cento.
- No Kiali do fog1, o tráfego para instâncias remotas aparece saindo pelo east-west gateway.

## Verifique seu entendimento

1. Edite manualmente o `weight` de um VS para 100/0 e gere carga de novo. Liste os VS com `kubectl -n app2 get vs` e edite um com `KUBE_EDITOR=nano kubectl -n app2 edit vs <nome>`. O CE "conserta" o VS ou a sua mudança permanece? O que isso diz sobre o momento em que o CE aplica as regras de load balancing?
2. Por que dividir pela **capacidade** (recursos alocados) faz mais sentido do que um round robin simples em fog heterogêneo?
3. Com `controlengine.loadblancing.enabled = false`, como o Istio distribuiria o tráfego? Teste, se houver tempo: em cada cluster, `sed -i 's/loadblancing.enabled = true/loadblancing.enabled = false/' ~/ce/controller-configmap-<cluster>.yaml`, reinicie o CE como no [M6](m6-placement-distribuido.md), passo 5, apague o `app2` e repita o M6 e este marco.

## Problemas comuns

| Sintoma | Causa provável | Diagnóstico |
|---|---|---|
| Kiali sem grafo | Prometheus sem dados ou carga não gerada | `kubectl -n istio-system logs deploy/prometheus` |
| Divisão igual entre instâncias | DR/VS de load balancing não aplicados | Log do CE: `LB_DEPLOYMENT_START` / `LB_COMMAND_EXECUTION_COMPLETED` |
| Contagem zerada num cluster | O tráfego não cruza a malha | `istioctl proxy-config endpoints` no a2m1 |

## Registro de execução

- Data:
- Pesos gerados × contagens observadas:
- Captura do Kiali (caminho do arquivo):
- M0–M7 concluídos? Sim / Não. O que falta:
