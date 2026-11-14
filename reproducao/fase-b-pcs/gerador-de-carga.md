# Gerador de carga e coleta de logs

## Objetivo

Preparar o PC `carga` para (1) submeter PRs e gerar tráfego HTTP sem disputar CPU com os clusters, (2) administrar os clusters de um só lugar e (3) centralizar os logs dos CEs com Grafana + Loki.

## Conceitos

As figuras do artigo vêm de duas fontes:
- **logs dos CEs**: eventos com timestamp (`utils/Events.java`), usados nos tempos de placement e deploy (Fig. 12–14) e na latência dos stores (Fig. 11);
- **latência das aplicações**: medida no cliente (Fig. 17).

Gerar a carga num PC de cluster roubaria CPU justamente do que está sendo medido, ainda mais em i5 de 4 núcleos. Por isso há um PC dedicado.

## Passos

### 1. Ferramentas

```bash
carga$ sudo apt install -y jq hey default-jre    # JRE para o JMeter
# JMeter: https://jmeter.apache.org/download_jmeter.cgi
```

O repositório traz planos de teste do JMeter em `ControlEngine/src/test/java/com/*.jmx` (submissão de PRs). Abra-os no JMeter para ver o que mediam e adapte host/porta/cabeçalhos.

### 2. Kubeconfigs centralizados

Graças ao SAN com o IP (M1, passo 2) e ao `apiserver-gateway` (M2), cada API server responde em `https://<IP>:6443`:

```bash
fog1$ kind get kubeconfig --name fog1 | sed -E 's#https://127.0.0.1:[0-9]+#https://192.168.0.11:6443#' > fog1.kubeconfig
# idem para fog2, cloud1; no fog3: k3d kubeconfig get fog3, com https://192.168.0.14:6443
carga$ scp fog1:fog1.kubeconfig fog2:fog2.kubeconfig cloud1:cloud1.kubeconfig fog3:fog3.kubeconfig ~/.kube/
carga$ export KUBECONFIG=$(ls ~/.kube/*.kubeconfig | paste -sd:)
carga$ kubectl config get-contexts
```

Esses arquivos dão **acesso administrativo**: não os copie para fora do laboratório nem os commite.

### 3. Scripts de PR

Guarde no `carga` os JSONs de PR do M5/M6 e um script que submeta N PRs em paralelo a um ou mais clusters. É o que o E3 vai precisar (5, 10 e 15 PRs simultâneos, Fig. 13). Escreva o script quando for usá-lo e guarde-o em `reproducao/scripts/`.

### 4. Grafana + Loki

O guia do repositório (`Prototype_Setup/docs/logging_setup.pdf`) instala o **Loki** com Helm, usando o MinIO como armazenamento (`Prototype_Setup/grafana-loki-setup/loki-values.yaml`), e o **Promtail** em cada cluster. O **Grafana** vem dos addons do Istio:

```bash
helm repo add grafana https://grafana.github.io/helm-charts
kubectl create ns logging && kubectl label ns logging istio-injection=enabled
# antes: crie no MinIO um bucket para os logs e ajuste o loki-values.yaml (endpoint, credenciais, bucket)
helm install loki grafana/loki -f loki-values.yaml -n logging
helm upgrade --install promtail grafana/promtail -n logging --set config.clients[0].url=http://loki-gateway.logging.svc.cluster.local/loki/api/v1/push
kubectl apply -f $ISTIO/samples/addons/grafana.yaml
```

Fixe as versões dos charts compatíveis com o Kubernetes em uso e registre-as. O `loki-values.yaml` do repositório é de um chart de 2022.

Onde instalar: pela simplicidade, um Loki no **cloud1**, recebendo o Promtail de todos os clusters pela malha. Para não pesar no cloud1, o PC `reserva` pode virar um quinto cluster só de monitoramento. Decida ao implantar e registre.

No Grafana, a consulta `{namespace="control-engine"} |= "NEW_PR_RECEIVED"` lista as chegadas de PR de todos os CEs.

## O que observar

- `kubectl --context kind-fog2 get pods -A` funciona a partir do `carga`.
- No Grafana, logs dos quatro CEs na mesma tela, com timestamps comparáveis (relógios sincronizados, [00](00-preparar-pcs-e-rede.md)).

## Verifique seu entendimento

1. Por que o timestamp gravado **dentro** da mensagem do CE (`- 1699999999999`) é mais confiável para medir do que o timestamp que o Loki atribui à linha?
2. Que evento marca o início e qual marca o fim do "tempo até o deploy" da Fig. 13?

## Registro de execução

- Data:
- Versões de JMeter, charts do Loki e Promtail:
- Onde o Loki foi instalado:
