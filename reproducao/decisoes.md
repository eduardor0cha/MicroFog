# Registro de decisões

Decisões tomadas no planejamento (2026-11-02), com as alternativas descartadas e o motivo. Antes de mudar uma delas, leia o motivo. Se mudar, registre aqui. Os números são estáveis: uma decisão retirada não é renumerada, para não quebrar referências.

## Objetivo e escopo

| # | Decisão | Alternativas consideradas | Motivo |
|---|---|---|---|
| D1 | Primeiro **ver funcionando**; a replicação fiel dos resultados vem depois | Replicar qualitativa ou quantitativamente desde o início | Os números do artigo dependem de hardware da Univ. de Melbourne e de uma WAN até a AWS que não temos. Primeiro entender o sistema |
| D2 | Executar **direto nos 6 PCs** do laboratório (decisão revista em 2026-11-16) | Ensaio prévio em 3 VMs num desktop | Os PCs já estão disponíveis. Um cluster KinD se recria em minutos a partir dos arquivos de configuração, o que dá o mesmo ponto de retorno que o snapshot de uma VM |
| D3 | O plano é **didático**: cada marco é uma lição | Runbook enxuto | O público (grupo de pesquisa) leu o artigo mas pode não tê-lo entendido por inteiro |
| D4 | Pré-requisito: Linux e Docker básicos. Kubernetes e Istio são ensinados nas lições | Exigir Kubernetes | É justamente o que falta a quem chega no MicroFog |
| D6 | Lições M0–M9, mais **fog3 (k3d), WAN emulada e gerador de carga**, para deixar o ambiente arquiteturalmente igual ao do artigo. Os experimentos E1–E5 ficam só esboçados | Parar no M7; ou já rodar E1–E5 | Do M0 ao M7 cada mecanismo central (placement, forwarding, deploy cruzado, load balancing) roda pelo menos uma vez. A replicação fiel depende de decisões ainda em aberto |

## Versões e imagens

| # | Decisão | Alternativas | Motivo |
|---|---|---|---|
| D13 | **Portão go/no-go**: tentar primeiro as versões de 2022 (KinD 0.14 / K8s 1.24.0, Istio 1.16, MetalLB 0.13); se não subirem no Ubuntu 26.04, usar versões atuais e registrar o motivo | Só 2022; só atuais | Teste barato. Se funcionar, ficamos mais perto da replicação fiel; se falhar, descobrimos cedo e com justificativa |
| D14 | **Compilar o CE e os microserviços a partir do fonte**, como primeira etapa (M0) | Usar as imagens publicadas | Necessário para qualquer extensão futura (algoritmo próprio, nova aplicação) e confirma que o código do repositório funciona |
| D15 | Manter **também** as imagens dos autores, selecionáveis por `IMAGE_SOURCE` (`local` como padrão, `upstream` como fallback/comparação), fixadas por **digest** | Só uma das origens | Fallback se o build de 2022 quebrar. Permite comparar o nosso build com o original. O digest protege contra a republicação da tag `latest` |
| D16 | Imagens próprias no **GHCR** (`ghcr.io/eduardor0cha/*`), pacote público | Docker Hub; registry local | O GHCR não tem o limite de pulls do Docker Hub, e o código já é GPL. Registry local (com pull-through cache) no PC `reserva` fica como plano B |
| D17 | Uma imagem por microserviço (como os autores), escopo **hcApp + app2** (7 imagens) | Imagem genérica com variáveis de ambiente | Preserva os manifestos originais. A imagem genérica exigiria mudar todos os YAMLs que vão para o MinIO |

## Infraestrutura

| # | Decisão | Alternativas | Motivo |
|---|---|---|---|
| D18 | **Um PC por cluster**: fog1, fog2 e cloud1 (KinD) nos PCs de 24 GB; fog3 (k3d) num PC de 16 GB; o outro PC de 16 GB como gerador de carga; o PC de 12 GB como reserva/monitoramento | PCs como nós reais (kubeadm/k3s, 2 PCs por cluster) | Repete a estrutura do artigo (uma VM por cluster, nós lógicos, mesmos nomes da Tabela 3) e inclui o fog3. Os configs do repositório pressupõem **um host por cluster**: mesmas portas 80/15443/6443 em todos e o "IP público da VM" no MetalLB e no Istio. O gerador de carga num PC separado não disputa CPU com os clusters |
| D19 | Rede com duas interfaces (revista em 2026-11-16): **cabo → switch** com roteador próprio como fonte principal (`192.168.0.11–16` por reserva DHCP; rota padrão e DNS do roteador; todo o tráfego MicroFog e a internet) e **Wi-Fi WPA2** só como redundância (rota padrão com métrica maior) | Tudo pela rede da faculdade; rota padrão pela Wi-Fi, com o roteador como plano B (versão anterior desta decisão) | O switch e o roteador estão sob nosso controle, livres de proxy/firewall, e só o nosso tráfego passa por eles. Custo: downloads passam pelo mesmo cabo que o tráfego medido, então os pulls de imagens são feitos antes das medições. A troca para a Wi-Fi não é automática se o roteador perder a internet com o link ativo ([00](licoes/00-preparar-pcs-e-rede.md), passo 2) |
| D12 | IP fixo no cabo por **reserva DHCP** no roteador do switch | DHCP comum; IP estático em cada PC | O IP do host fica gravado no certificado do API server, no MetalLB, no `loadBalancerIP`, no `meshNetworks` e nos remote secrets. Se mudar, a malha quebra. A reserva mantém a configuração num lugar só (o roteador) |
| D27 | Hostnames `pc-lamp-1` a `pc-lamp-6` (PC*n* → `192.168.0.1n`), com o papel (`fog1`, `carga` etc.) como apelido no `/etc/hosts` | Hostname igual ao papel | Os hostnames já são os do laboratório. O apelido mantém os comandos das lições (`fog1$`, `scp fog1:`) |
| D28 | Chrony (já vem no Ubuntu 26.04) com NTP comum no lugar das fontes NTS padrão: o `carga` sincroniza com servidores NTP públicos e serve a hora aos outros PCs pelo cabo (`local stratum 10` como reserva). A configuração fica em arquivos próprios em `sources.d/` e `conf.d/` | Manter o NTS padrão; cada PC direto na internet; NTP interno `172.19.176.12` | A rede recusa a negociação NTS (TCP 4460: `Connection refused` e `Cook 0` em todas as fontes, 2026-11-16), então o chrony padrão não sincronizava em nenhum PC (PC6 ~47 s adiantado). O NTP comum (UDP 123) passa (teste de 2026-11-14). Uma referência única no cabo mantém os PCs coerentes entre si. O NTP interno respondeu ~1 s fora dos públicos |
| D20 | Monitoramento: Prometheus + Kiali no M7; Grafana + Loki na lição do gerador de carga | Pilha completa desde o início | O Kiali é necessário para o M7. A coleta de logs só vira medição depois, com o gerador de carga |

## Desvios dos arquivos originais (descobertos ao ler o código)

| # | Desvio | Evidência | Onde |
|---|---|---|---|
| D21 | `controller-vs.yaml` reescrito para rotear **só pelo cabeçalho `cluster`** | O VS original roteia `/executeCommands` e `/getDeviceData`, mas o código usa `/getClusterData` e `/submitDeploymentInfo` (`PlacementLogicExecutor.java:214, :443`): sem rota, o Envoy responde 404 | [M4](licoes/m4-control-engine.md), passos 1 e 5 |
| D22 | `controlengine.forwardpolicy = to_rand_fog` no fog1 e no fog2 | Os ConfigMaps trazem `to_fog_cloud`, mas `ForwardingPolicy.java` só reconhece `to_rand_fog` e `to_cloud`. Qualquer outro valor devolve `null`, e não há forwarding | [M4](licoes/m4-control-engine.md), passo 2 |
| D23 | M5 começa com entrada no **cloud1**, e só depois no fog1 | O guia original usa um fog | O cloud1 tem os maiores nós (4 vCPU / 7 GB lógicos) e comporta o hcApp sem forwarding. Começar por um placement que não precisa de forwarding deixa uma variável a menos | [M5](licoes/m5-placement-local.md) |
| D24 | MinIO fixado numa release de jan/2023 e Redis em `7.0` | Os manifestos usam `latest`, e a edição comunitária do MinIO mudou muito em 2025 | [M3](licoes/m3-data-stores.md), passo 0 |
| D25 | Console do MinIO e Kiali por `port-forward`, sem `minioGW`/`minioVS`/`kiali-*` | Todos usam a porta 80 do ingress com hosts `"*"`, junto com o CE e as aplicações | M3, M7 |
| D26 | `requests` do `istiod` reduzidos (100m / 512 Mi) | O padrão (500m / 2 GiB) pesa nos nós lógicos pequenos (1,5 vCPU / 3 GB) e reduz o allocatable que o CE enxerga | [M2](licoes/m2-malha-istio.md), passo 2 |
| D29 | Subset `cloud1` da `control-engine-dr` corrigido para o rótulo `cluster: cloud1` | `controller-dr.yaml` seleciona `cluster: cloud2`, mas `controller-cloud1.yaml` rotula o pod com `cluster: cloud1`: o subset ficaria vazio | [M4](licoes/m4-control-engine.md), passo 1 |

Hipótese para D21 e D22: a imagem publicada `samodha/microfog:latest` pode ter sido construída de uma versão do código anterior à do repositório. O M4, passo 5, testa isso.

## Em aberto

| # | Questão | Quando decidir |
|---|---|---|
| A1 | **Perfil da WAN emulada** fog↔cloud. Para *ver funcionando*, qualquer valor perceptível serve (ex.: 50 ms). Para a *replicação fiel*, o artigo usou Melbourne → AWS ap-southeast-2 (Sydney), cuja RTT típica é de ~10–20 ms, e não uma rota intercontinental | Lição da [WAN emulada](licoes/wan-netem.md) |
| A2 | **Tamanhos lógicos dos nós.** A Tabela 2 soma 54 vCPU / 122 GB, e temos 24 núcleos / ~107 GiB utilizáveis (levantamento de 2026-11-14). Nenhum nó KinD pode ter allocatable maior que o host (4 núcleos), e a Tabela 2 tem nós de 5 vCPU. Proposta inicial (Tabela 2 × 0,5) no [M1](licoes/m1-clusters.md#tamanhos-lógicos-dos-nós-questão-em-aberto-a2) | M1 |
| A3 | Número de repetições, métricas e comparação estatística dos experimentos E1–E5 | Plano de replicação fiel |
| A4 | Onde publicar o plano (fork no GitHub) e se os configs testados viram arquivos versionados | Depois do M7 |
| A5 | **etcd em disco mecânico.** Todos os PCs usam HDD, e o etcd faz `fsync` a cada escrita. Isso pode deixar o deploy lento e distorcer tempos como os da Fig. 14. Opções: `unsafe-no-fsync` no etcd (aceitável em laboratório descartável) ou etcd em `tmpfs`. Decidir após medir no M1 (`etcd` com avisos `slow fdatasync` nos logs) | M1 |
