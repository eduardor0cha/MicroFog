# Registro de decisões

Decisões tomadas no planejamento (2026-11-02), com as alternativas descartadas e o motivo. Antes de mudar uma delas, leia o motivo. Se mudar, registre aqui.

## Objetivo e escopo

| # | Decisão | Alternativas consideradas | Motivo |
|---|---|---|---|
| D1 | Primeiro **ver funcionando**; a replicação fiel dos resultados vem depois | Replicar qualitativa ou quantitativamente desde o início | Os números do artigo dependem de hardware da Univ. de Melbourne e de uma WAN até a AWS que não temos. Primeiro entender o sistema |
| D2 | Duas fases: **A** (3 VMs num desktop) como ensaio da **B** (6 PCs) | Ir direto aos PCs | Erros de configuração da malha Istio custam menos numa VM com snapshot |
| D3 | O plano é **didático**: cada marco é uma lição | Runbook enxuto | O público (grupo de pesquisa) leu o artigo mas pode não tê-lo entendido por inteiro |
| D4 | Pré-requisito: Linux e Docker básicos. Kubernetes e Istio são ensinados nas lições | Exigir Kubernetes | É justamente o que falta a quem chega no MicroFog |
| D5 | Fase A concluída no **M7**. M8 (centralizado) e M9 (failover) ficam para a Fase B | Incluir M8/M9 na Fase A | Do M0 ao M7 cada mecanismo central (placement, forwarding, deploy cruzado, load balancing) roda pelo menos uma vez |
| D6 | Fase B: refazer M1–M7, **acrescentar fog3 (k3d), WAN emulada, gerador de carga, M8 e M9**. Os experimentos E1–E5 ficam só esboçados | Só refazer a Fase A; ou já rodar E1–E5 | Deixar o ambiente arquiteturalmente igual ao do artigo. A replicação fiel depende de decisões ainda em aberto |

## Infraestrutura — Fase A

| # | Decisão | Alternativas | Motivo |
|---|---|---|---|
| D7 | Desktop Windows **x86** (Ryzen 7 5700X, 32 GB) | VM no Mac | Todas as imagens publicadas pelos autores são **somente amd64**. O Mac é ARM |
| D8 | **3 VMs** (fog1, fog2, cloud1), cada uma com 4 vCPU / 8 GB, em rede **bridged** | 1 VM com 3 clusters KinD | Os configs do repositório pressupõem **um host por cluster** (mesmas portas 80/15443/6443 em todos, "IP público da VM" no MetalLB/Istio). Uma VM por cluster ensaia exatamente o que será feito nos PCs |
| D9 | Hyper-V se o Windows for Pro (gratuito); senão, VirtualBox | VMware Workstation | O Hyper-V tem o melhor desempenho no Windows e convive com WSL2 |
| D10 | Topologia reduzida: fog1 e fog2 com 1 control-plane + 2 workers; cloud1 com 1 control-plane + 1 worker | Mesmo número de nós do artigo (4/5/2) | Cada nó KinD custa ~300–500 MB. Com 5 nós, o fog2 não caberia em 8 GB junto com Istio e CE |
| D11 | Só KinD na Fase A, como no repositório | Incluir k3d | O fog3/k3d não existe no repositório e não é necessário para ver funcionando |
| D12 | IP fixo para cada VM na rede doméstica | DHCP | O IP do host fica gravado no certificado do API server, no MetalLB, no `loadBalancerIP`, no `meshNetworks` e nos secrets remotos. Se mudar, a malha quebra |

## Versões e imagens

| # | Decisão | Alternativas | Motivo |
|---|---|---|---|
| D13 | **Portão go/no-go**: tentar primeiro as versões de 2022 (KinD 0.14 / K8s 1.24.0, Istio 1.16, MetalLB 0.13); se não subirem no Ubuntu 26.04, usar versões atuais e registrar o motivo | Só 2022; só atuais | Teste barato. Se funcionar, ficamos mais perto da replicação fiel; se falhar, descobrimos cedo e com justificativa |
| D14 | **Compilar o CE e os microserviços a partir do fonte**, como primeira etapa da Fase A | Usar as imagens publicadas | Necessário para qualquer extensão futura (algoritmo próprio, nova aplicação) e confirma que o código do repositório funciona |
| D15 | Manter **também** as imagens dos autores, selecionáveis por `IMAGE_SOURCE` (`local` como padrão, `upstream` como fallback/comparação), fixadas por **digest** | Só uma das origens | Fallback se o build de 2022 quebrar. Permite comparar o nosso build com o original. O digest protege contra a republicação da tag `latest` |
| D16 | Imagens próprias no **GHCR** (`ghcr.io/eduardor0cha/*`), pacote público | Docker Hub; registry local | O GHCR não tem o limite de pulls do Docker Hub, e o código já é GPL. Registry local (com pull-through cache) fica como plano B na Fase B |
| D17 | Uma imagem por microserviço (como os autores), escopo **hcApp + app2** (7 imagens) | Imagem genérica com variáveis de ambiente | Preserva os manifestos originais. A imagem genérica exigiria mudar todos os YAMLs que vão para o MinIO |

## Infraestrutura — Fase B

| # | Decisão | Alternativas | Motivo |
|---|---|---|---|
| D18 | **Um PC por cluster**: fog1, fog2 e cloud1 (KinD) nos PCs de 24 GB; fog3 (k3d) num PC de 16 GB; o outro PC de 16 GB como gerador de carga; o PC de 12 GB como reserva/monitoramento | PCs como nós reais (kubeadm/k3s, 2 PCs por cluster) | Repete a estrutura do artigo (nós lógicos, mesmos nomes da Tabela 3), inclui o fog3 e reaproveita a receita da Fase A. O gerador de carga num PC separado não disputa CPU com os clusters |
| D19 | Rede com duas interfaces: **cabo → switch** com roteador próprio (`192.168.0.11–16` por reserva DHCP; gateway do roteador ignorado; todo o tráfego MicroFog) e **Wi-Fi WPA2 → internet** (rota padrão) | Tudo pela rede da faculdade; rota padrão pelo roteador do switch | O switch fica livre de proxy/firewall, e só o nosso tráfego afeta medições futuras. O roteador também dá internet, mas manter downloads na Wi-Fi tira esse tráfego do cabo medido; ele fica como plano B |
| D27 | Hostnames `pc-lamp-1` a `pc-lamp-6` (PC*n* → `192.168.0.1n`), com o papel (`fog1`, `carga` etc.) como apelido no `/etc/hosts` | Hostname igual ao papel | Os hostnames já são os do laboratório. O apelido mantém os comandos das lições (`fog1$`, `scp fog1:`) |
| D28 | Chrony no lugar do `systemd-timesyncd`: o `carga` sincroniza com servidores NTP públicos e serve a hora aos outros PCs pelo cabo (`local stratum 10` como reserva) | Cada PC direto na internet; NTP interno `172.19.176.12` | Teste de 2026-11-14: o NTP **não** é bloqueado, mas o timesyncd não sincronizava em nenhum PC (PC6 ~47 s adiantado). Uma referência única no cabo mantém os PCs coerentes entre si. O NTP interno respondeu ~1 s fora dos públicos |
| D20 | Monitoramento: Prometheus + Kiali na Fase A; Grafana + Loki na Fase B | Pilha completa desde o início | O Kiali é necessário para o M7. A coleta de logs só vira medição na Fase B |

## Desvios dos arquivos originais (descobertos ao ler o código)

| # | Desvio | Evidência | Onde |
|---|---|---|---|
| D21 | `controller-vs.yaml` reescrito para rotear **só pelo cabeçalho `cluster`** | O VS original roteia `/executeCommands` e `/getDeviceData`, mas o código usa `/getClusterData` e `/submitDeploymentInfo` (`PlacementLogicExecutor.java:214, :443`): sem rota, o Envoy responde 404 | [M4](fase-a-vm/m4-control-engine.md), passos 1 e 5 |
| D22 | `controlengine.forwardpolicy = to_rand_fog` no fog1 e no fog2 | Os ConfigMaps trazem `to_fog_cloud`, mas `ForwardingPolicy.java` só reconhece `to_rand_fog` e `to_cloud`. Qualquer outro valor devolve `null`, e não há forwarding | [M4](fase-a-vm/m4-control-engine.md), passo 2 |
| D23 | M5 com entrada no **cloud1** | Com os nós da Fase A, o hcApp (2,5 CPU + sidecars) não cabe num fog de 4 vCPU que já roda Istio, CE e stores | [M5](fase-a-vm/m5-placement-local.md) |
| D24 | MinIO fixado numa release de jan/2023 e Redis em `7.0` | Os manifestos usam `latest`, e a edição comunitária do MinIO mudou muito em 2025 | [M3](fase-a-vm/m3-data-stores.md), passo 0 |
| D25 | Console do MinIO e Kiali por `port-forward`, sem `minioGW`/`minioVS`/`kiali-*` | Todos usam a porta 80 do ingress com hosts `"*"`, junto com o CE e as aplicações | M3, M7 |
| D26 | `requests` do `istiod` reduzidos (100m / 512 Mi) | O padrão (500m / 2 GiB) não cabe nos nós pequenos e reduz o allocatable que o CE enxerga | [M2](fase-a-vm/m2-malha-istio.md), passo 2 |

Hipótese para D21 e D22: a imagem publicada `samodha/microfog:latest` pode ter sido construída de uma versão do código anterior à do repositório. O M4, passo 5, testa isso.

## Em aberto

| # | Questão | Quando decidir |
|---|---|---|
| A1 | **Perfil da WAN emulada** fog↔cloud. Para *ver funcionando*, qualquer valor perceptível serve (ex.: 50 ms). Para a *replicação fiel*, o artigo usou Melbourne → AWS ap-southeast-2 (Sydney), cuja RTT típica é de ~10–20 ms, e não uma rota intercontinental | Fase B ([wan-netem.md](fase-b-pcs/wan-netem.md)) |
| A2 | **Tamanhos lógicos dos nós na Fase B.** A Tabela 2 soma 54 vCPU / 122 GB, e temos 24 núcleos / ~107 GiB utilizáveis (levantamento de 2026-11-14). Nenhum nó KinD pode ter allocatable maior que o host (4 núcleos), e a Tabela 2 tem nós de 5 vCPU. Proposta inicial em [m1-m7-nos-pcs.md](fase-b-pcs/m1-m7-nos-pcs.md) | Ao iniciar a Fase B |
| A3 | Número de repetições, métricas e comparação estatística dos experimentos E1–E5 | Plano de replicação fiel |
| A4 | Onde publicar o plano (fork no GitHub) e se os configs testados viram arquivos versionados | Depois da Fase A |
| A5 | **etcd em disco mecânico.** Todos os PCs usam HDD, e o etcd faz `fsync` a cada escrita. Isso pode deixar o deploy lento e distorcer tempos como os da Fig. 14. Opções: `unsafe-no-fsync` no etcd (aceitável em laboratório descartável) ou etcd em `tmpfs`. Decidir após medir no M1 (`etcd` com avisos `slow fdatasync` nos logs) | M1 da Fase B |
