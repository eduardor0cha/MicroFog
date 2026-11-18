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

O `jq` e o `hey` já vieram no [00](00-preparar-pcs-e-rede.md), passo 8. O JMeter é o que os autores usaram para submeter PRs, e precisa de Java.

`carga$` (pc-lamp-5):

```bash
sudo apt install -y default-jre
JMETER_VERSION=5.6.3
cd ~ && curl -LO https://archive.apache.org/dist/jmeter/binaries/apache-jmeter-$JMETER_VERSION.tgz
tar xzf apache-jmeter-$JMETER_VERSION.tgz && rm apache-jmeter-$JMETER_VERSION.tgz
echo "export PATH=\$PATH:$HOME/apache-jmeter-$JMETER_VERSION/bin" >> ~/.bashrc && source ~/.bashrc
jmeter --version
```

O repositório traz planos de teste do JMeter em `ControlEngine/src/test/java/com/*.jmx` (submissão de PRs). O `carga` não tem interface gráfica, então leia os planos pelo texto. O host e a porta são os do ambiente dos autores (`172.18.255.2:80`):

```bash
cd ~/MicroFog/ControlEngine/src/test/java/com
grep -n -o -E 'name="HTTPSampler\.(domain|port|path|method)">[^<]*' *.jmx
grep -n -A3 'HeaderManager' *.jmx | grep -E 'Header\.(name|value)'
```

Para usar um plano, troque o host pelo IP do cluster de entrada numa cópia e rode o JMeter sem interface (`-n`). O `-l` grava os resultados:

```bash
cp "HTTP Request.jmx" ~/pr.jmx
sed -i 's#name="HTTPSampler.domain">172.18.255.2#name="HTTPSampler.domain">192.168.0.11#' ~/pr.jmx
jmeter -n -t ~/pr.jmx -l ~/pr-resultados.jtl
```

Confira também o caminho e os cabeçalhos (`Host`, `cluster`) na cópia antes de rodar: o plano dos autores chama `/PR/home`, e as APIs do M4 ficam em `/MicroFog/...`.

### 2. Kubeconfigs centralizados

Administrar os quatro clusters a partir do `carga` evita entrar em cada PC para cada comando. Graças ao SAN com o IP (M1, passo 2) e ao `apiserver-gateway` (M2), cada API server responde em `https://<IP>:6443`. Cada PC exporta o seu kubeconfig trocando o endereço local pelo IP do cabo.

`fog1$` (pc-lamp-1):

```bash
kind get kubeconfig --name fog1 | sed -E 's#https://[0-9.]+:[0-9]+#https://192.168.0.11:6443#' > ~/fog1.kubeconfig
```

`fog2$` (pc-lamp-2):

```bash
kind get kubeconfig --name fog2 | sed -E 's#https://[0-9.]+:[0-9]+#https://192.168.0.12:6443#' > ~/fog2.kubeconfig
```

`cloud1$` (pc-lamp-3):

```bash
kind get kubeconfig --name cloud1 | sed -E 's#https://[0-9.]+:[0-9]+#https://192.168.0.13:6443#' > ~/cloud1.kubeconfig
```

`fog3$` (pc-lamp-4):

```bash
k3d kubeconfig get fog3 | sed -E 's#https://[0-9.]+:[0-9]+#https://192.168.0.14:6443#' > ~/fog3.kubeconfig
```

`carga$` (pc-lamp-5) copie os quatro e junte-os. O `KUBECONFIG` com vários arquivos separados por `:` faz o `kubectl` enxergar os quatro contextos; grave-o no `~/.bashrc` para valer em todo shell novo:

```bash
mkdir -p ~/.kube
scp fog1:fog1.kubeconfig fog2:fog2.kubeconfig cloud1:cloud1.kubeconfig fog3:fog3.kubeconfig ~/.kube/
chmod 600 ~/.kube/*.kubeconfig
echo 'export KUBECONFIG=$(ls ~/.kube/*.kubeconfig | paste -sd:)' >> ~/.bashrc && source ~/.bashrc
kubectl config get-contexts        # kind-fog1, kind-fog2, kind-cloud1, k3d-fog3
```

Esses arquivos dão **acesso administrativo**: não os copie para fora do laboratório nem os commite.

### 3. Scripts de PR

`carga$` (pc-lamp-5) os JSONs de PR do M5 e do M6 já estão no `carga` (`~/pr-hcapp.json`, `~/pr-hcapp-fog1.json`, `~/pr-app2.json`). Confira:

```bash
ls ~/pr-*.json
```

O E3 vai precisar de um script que submeta N PRs em paralelo a um ou mais clusters (5, 10 e 15 PRs simultâneos, Fig. 13). Ele não é escrito agora porque depende de como o E3 for montado (quais aplicações, em quais clusters), o que está em [`experimentos/`](../experimentos/README.md). Quando escrevê-lo, guarde-o em `reproducao/scripts/`.

### 4. Grafana + Loki

O guia do repositório (`Prototype_Setup/docs/logging_setup.pdf`) instala o **Loki** com Helm, usando o MinIO como armazenamento (`Prototype_Setup/grafana-loki-setup/loki-values.yaml`), e o **Promtail** em cada cluster. O **Grafana** vem dos addons do Istio.

Onde instalar: pela simplicidade, um Loki no **cloud1**, recebendo o Promtail de todos os clusters pela malha. É o que os comandos abaixo fazem. Para não pesar no cloud1, o PC `reserva` pode virar um quinto cluster só de monitoramento; se fizer isso, registre a mudança.

**Buckets.** O `loki-values.yaml` já aponta para o MinIO do M3 (`minio.control-engine.svc.cluster.local:9000`, `minioadmin`/`minioadmin`) e usa os buckets `loki` e `admin`, que ainda não existem. `cloud1$` (pc-lamp-3) com o port-forward do M3, passo 2, ativo noutro terminal:

```bash
grep -n -A3 'bucketNames:' ~/MicroFog/Prototype_Setup/grafana-loki-setup/loki-values.yaml    # chunks/ruler: loki; admin: admin
mc mb cloud1/loki cloud1/admin
```

**Versões dos charts.** Um chart atual não aceita as mesmas chaves do `loki-values.yaml`. Comparado com os `values.yaml` dos charts publicados, ele bate com o chart `loki` **4.4.2** (jan/2023, Loki 2.7.2): as únicas diferenças são as personalizações dos autores (buckets, endpoint e credenciais do MinIO, `auth_enabled`). O Promtail da mesma época é o chart **6.8.2**. O `helm template` valida o arquivo de valores sem instalar nada.

`cloud1$` (pc-lamp-3):

```bash
helm repo add grafana https://grafana.github.io/helm-charts && helm repo update
LOKI_CHART=4.4.2
helm template loki grafana/loki --version $LOKI_CHART -n logging \
  -f ~/MicroFog/Prototype_Setup/grafana-loki-setup/loki-values.yaml > /dev/null && echo "valores aceitos"
```

**Loki.** `cloud1$` (pc-lamp-3):

```bash
kubectl create ns logging && kubectl label ns logging istio-injection=enabled
helm install loki grafana/loki --version $LOKI_CHART -n logging \
  -f ~/MicroFog/Prototype_Setup/grafana-loki-setup/loki-values.yaml
kubectl -n logging get pods,svc       # o Service loki-gateway deve existir
```

**Service do Loki nos outros clusters.** O Promtail dos outros clusters envia para `loki-gateway.logging.svc.cluster.local`. Esse nome só resolve num cluster onde o Service existe, mesmo sem pods locais; é o mesmo padrão do `minio` e do `redis` no M3. `cloud1$` (pc-lamp-3) exporte o Service sem os campos que o cluster preenche e envie-o aos outros PCs:

```bash
kubectl -n logging get svc loki-gateway -o json \
  | jq 'del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp, .metadata.managedFields,
            .metadata.annotations, .spec.clusterIP, .spec.clusterIPs, .status)' > ~/loki-gateway-svc.json
for h in fog1 fog2 fog3; do scp ~/loki-gateway-svc.json $h:; done
```

`fog1$` (pc-lamp-1), `fog2$` (pc-lamp-2) e `fog3$` (pc-lamp-4):

```bash
kubectl create ns logging && kubectl label ns logging istio-injection=enabled
kubectl apply -f ~/loki-gateway-svc.json
```

**Promtail.** `clusters$` (pc-lamp-1 a 4):

```bash
PROMTAIL_CHART=6.8.2
helm repo add grafana https://grafana.github.io/helm-charts && helm repo update
helm upgrade --install promtail grafana/promtail --version $PROMTAIL_CHART -n logging \
  --set 'config.clients[0].url=http://loki-gateway.logging.svc.cluster.local/loki/api/v1/push'
kubectl -n logging get pods -l app.kubernetes.io/name=promtail
```

**Grafana.** `cloud1$` (pc-lamp-3) instale o addon do Istio e abra-o por port-forward, como o Kiali no M7 (o terminal fica ocupado até `Ctrl+C`):

```bash
kubectl apply -f $ISTIO/samples/addons/grafana.yaml
kubectl -n istio-system rollout status deploy/grafana
kubectl -n istio-system port-forward --address 0.0.0.0 svc/grafana 3000:3000
```

Abra `http://192.168.0.13:3000` num computador ligado ao switch. Em *Connections → Data sources → Add data source → Loki*, use a URL `http://loki-gateway.logging.svc.cluster.local` e clique em *Save & test*.

Em *Explore*, com a fonte Loki, a consulta `{namespace="control-engine"} |= "NEW_PR_RECEIVED"` lista as chegadas de PR de todos os CEs.

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
