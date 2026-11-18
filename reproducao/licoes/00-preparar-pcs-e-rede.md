# 00 — Preparar os PCs e a rede

## Objetivo

Seis PCs com Ubuntu Server 26.04.1, cada um com um papel definido. Todos falam entre si pelo **switch** (cabo, IP fixo por reserva DHCP no roteador do switch), acessam a internet pelo **roteador do switch** (com a **Wi-Fi** como redundância), têm os relógios sincronizados e já trazem Docker e as ferramentas de linha de comando que as próximas lições usam.

## Conceitos

### Um PC por cluster

No artigo (Fig. 1 e §6.1.1), cada **cluster** é um cluster Kubernetes independente: fog1, fog2, fog3 e cloud1. Cada um fica numa rede diferente e é exposto ao mundo por um load balancer. Os autores criaram **uma VM por cluster** e, dentro de cada VM, um cluster **KinD**.

O KinD (*Kubernetes in Docker*) roda cada **nó** do Kubernetes como um **container Docker**. É assim que uma única VM de 16 vCPU vira um cluster de 4 "nós" heterogêneos na Tabela 2. Vamos fazer o mesmo, com um PC no lugar de cada VM (decisão D18):

```
pc-lamp-1 (fog1)   ── Docker ── cluster KinD "fog1"   (4 nós-container)
pc-lamp-2 (fog2)   ── Docker ── cluster KinD "fog2"   (5 nós-container)
pc-lamp-3 (cloud1) ── Docker ── cluster KinD "cloud1" (2 nós-container)
pc-lamp-4 (fog3)   ── Docker ── cluster k3d  "fog3"   (3 nós-container)
pc-lamp-5 (carga)  ── gerador de carga, administração, build, servidor NTP
pc-lamp-6 (reserva)
```

### Papéis (decisão D18)

| PC | RAM | Papel | Hostname | IP no cabo |
|---|---|---|---|---|
| PC1 | 24 GB | cluster **fog1** (KinD, 4 nós) | `pc-lamp-1` | `192.168.0.11` |
| PC2 | 24 GB | cluster **fog2** (KinD, 5 nós) | `pc-lamp-2` | `192.168.0.12` |
| PC3 | 24 GB | cluster **cloud1** (KinD, 2 nós) + WAN emulada | `pc-lamp-3` | `192.168.0.13` |
| PC4 | 16 GB | cluster **fog3** (k3d, 3 nós) | `pc-lamp-4` | `192.168.0.14` |
| PC5 | 16 GB | **gerador de carga**, administração, build das imagens, servidor NTP | `pc-lamp-5` | `192.168.0.15` |
| PC6 | 12 GB | **reserva** / monitoramento central / registry local (plano B, D16) | `pc-lamp-6` | `192.168.0.16` |

Levantamento de 2026-11-14:

- **CPU:** todos têm um Intel Core i5-4570, de 4ª geração, com 4 núcleos e sem hyper-threading.
- **Disco:** todos usam **disco rígido mecânico** (HDD). O volume LVM da raiz tem 98 GB, num disco de 1 TB nos PCs 1–2 e de 500 GB nos PCs 3–6.
- **Sistema:** Ubuntu 26.04.1, kernel 7.0 e cgroup v2.
- **Memória utilizável** (`free -g`): ~22 GiB nos PCs 1–3, ~15 GiB nos PCs 4–5 e ~11 GiB no PC6.

A Tabela 2 soma 54 vCPU e 122 GB; temos 24 núcleos e ~107 GiB utilizáveis. Os tamanhos lógicos dos nós ficam no [M1](m1-clusters.md#tamanhos-lógicos-dos-nós-questão-em-aberto-a2) (questão em aberto A2).

### O "IP público da VM"

Os guias originais falam em `<PUBLIC_IP_OF_THE_VM>`: é o endereço pelo qual **os outros clusters** alcançam este. No nosso caso, é o **IP do PC no cabo** (`192.168.0.11` a `.14`). Ele vai ser gravado em vários lugares (certificado do API server, MetalLB, `loadBalancerIP`, `meshNetworks`, remote secrets) e por isso **precisa ser fixo** (D12).

### Duas interfaces (decisão D19)

```
   internet ── roteador ── switch (192.168.0.0/24, reserva DHCP por MAC; rota padrão)
   ┌──────┬──────┬──────┬──────┬──────┬──────┐
  fog1   fog2  cloud1  fog3  carga  reserva      ← tráfego MicroFog: 80, 6443, 15443, PRs
  (.11)  (.12)  (.13)  (.14)  (.15)  (.16)
   │      │      │      │      │      │
   └──────┴──────┴──────┴──────┴──────┴──── Wi-Fi WPA2 → internet (redundância)
```

- O **IP do cabo** é o "IP público da VM" dos guias.
- O **roteador do switch** é a fonte principal: dá o IP fixo, a rota padrão e o DNS. O tráfego MicroFog e a internet (`apt`, pull de imagens, GHCR) saem pelo cabo.
- A **Wi-Fi** é só redundância: tem rota padrão com métrica maior, usada se o cabo cair. Ela **não pode** ser a rota entre os PCs.
- Como os downloads passam pelo mesmo cabo que o tráfego medido, faça os pulls de imagens **antes** de cada medição, nunca durante.

## Passos

### 1. Instalar o Ubuntu

Ubuntu Server 26.04.1 marcando **OpenSSH server**. Ele é necessário porque todos os PCs são administrados por SSH a partir do `carga` (passo 4).

**Não** instale o Docker pelo instalador. Ele usa o snap, que guarda a configuração em `/var/snap/docker/` em vez de `/etc/docker/`, e o `daemon.json` do passo 6 não teria efeito. Vamos usar o pacote apt (passo 6).

Instale com o cabo conectado: o roteador do switch dá internet. A Wi-Fi é configurada no passo 2. Confira se o `wpasupplicant`, que o Ubuntu Server usa para Wi-Fi, está instalado. Sem ele, a Wi-Fi não sobe:

```bash
dpkg -l wpasupplicant                 # "ii" no começo da linha = instalado
sudo apt install -y wpasupplicant     # só se não estiver
```

Na BIOS: desative suspensão e hibernação, e ative "power on after AC loss" se existir. Um PC que suspende no meio de um experimento derruba o cluster inteiro dele, e o "power on after AC loss" faz o PC voltar sozinho depois de uma queda de energia.

### 2. Reserva DHCP e netplan com duas interfaces

`todas$` (pc-lamp-1 a 6) veja os nomes das interfaces e o MAC da cabeada:

```bash
ip -br link      # 1ª coluna: nome; 3ª coluna: MAC
```

A cabeada é `eno1` em todos os PCs. A Wi-Fi é `wlp2s0`, exceto no **PC2**, onde é `wlp3s0`.

No roteador do switch (pela página de administração dele, no navegador), reserve para cada PC o IP da tabela de papéis, associado ao MAC do `eno1`. O IP do cabo vai para certificados e configurações do Istio (D12), então a reserva **não pode** mudar.

`todas$` (pc-lamp-1 a 6) veja que arquivo o instalador criou em `/etc/netplan/`:

```bash
ls /etc/netplan/
```

Abra esse arquivo. O nome pode variar; os comandos abaixo usam `00-installer-config.yaml`:

```bash
sudo nano /etc/netplan/00-installer-config.yaml
```

Apague o conteúdo e cole o bloco abaixo, com `wlp3s0` no lugar de `wlp2s0` no PC2 e o nome e a senha da Wi-Fi. Salve com `Ctrl+O`, `Enter`, e saia com `Ctrl+X`:

```yaml
network:
  version: 2
  ethernets:
    eno1:
      dhcp4: true
      dhcp4-overrides:
        route-metric: 100     # rota padrão principal: roteador do switch
  wifis:
    wlp2s0:
      dhcp4: true
      dhcp4-overrides:
        route-metric: 600     # redundância: só é usada se a rota do cabo sumir
      access-points:
        "NOME_DA_REDE":
          password: "SENHA"
```

O netplan reclama quando o arquivo, que guarda a senha da Wi-Fi, pode ser lido por outros usuários. Restrinja as permissões e aplique:

```bash
sudo chmod 600 /etc/netplan/00-installer-config.yaml
sudo netplan apply
ip -4 addr show eno1      # deve mostrar o IP reservado (ex.: 192.168.0.11 no PC1)
ip route                  # duas rotas "default": eno1 com metric 100 e Wi-Fi com metric 600
ip route get 1.1.1.1      # deve sair pelo eno1
ping -c2 192.168.0.12      # deve sair pelo eno1
ip route get 192.168.0.12
```

A troca para a Wi-Fi só é automática quando a rota do cabo some, por exemplo com o cabo desconectado. Se o roteador perder a internet mas o link continuar ativo, a rota pelo cabo continua lá, e a troca é manual:

```bash
sudo ip route del default dev eno1    # a internet passa a sair pela Wi-Fi; o tráfego entre PCs continua no cabo
sudo netplan apply                    # volta ao normal quando o roteador se recuperar
```

### 3. Conferir conflitos de faixa de IP

O Docker cria as suas redes em `172.17.0.0/16`, `172.18.0.0/16`, `172.19.0.0/16` e assim por diante, e a rede `kind` costuma ficar em `172.18.0.0/16`. Veja que faixa a Wi-Fi entrega:

```bash
ip -4 addr show wlp2s0     # wlp3s0 no PC2
```

Se ela cair em `172.16.0.0/12`, as redes do Docker podem cair por cima dela. **No laboratório é o caso**: a Wi-Fi entrega `172.23.64.0/20`, e o DNS do roteador do switch fica em `172.19.176.12`. Por isso, o passo 6 muda as faixas do Docker **antes** de criar qualquer cluster.

Confira também se a Wi-Fi **não** entrega endereços em `192.168.0.0/24`, a faixa do cabo. Ela é o padrão de muitos roteadores domésticos. Se coincidir, haverá duas rotas para a mesma sub-rede, e o tráfego entre os PCs pode sair pela Wi-Fi (ou não chegar). Nesse caso, mude a faixa do roteador do switch (que está sob nosso controle) e troque `192.168.0.` em todas as lições.

### 4. Nomes, SSH e administração

O hostname de cada PC é `pc-lamp-<n>`, com `<n>` igual ao número do PC. `todas$` (pc-lamp-1 a 6), trocando o número em cada PC:

```bash
sudo hostnamectl set-hostname pc-lamp-1    # pc-lamp-2 no PC2, e assim por diante
hostname                                    # confere
```

As lições se referem aos PCs pelo **papel** (`fog1$`, `carga$`, `scp fog1:...`). Sem DNS no switch, quem traduz esses nomes em IPs é o `/etc/hosts` de cada PC, que registra o hostname e o papel como apelido. `todas$` (pc-lamp-1 a 6):

```bash
sudo nano /etc/hosts
```

**Apague** a linha que começa com `127.0.1.1`. O instalador a cria com o hostname antigo, e ela faria o próprio nome do PC apontar para o loopback em vez do IP do cabo. Acrescente ao final do arquivo e salve (`Ctrl+O`, `Enter`, `Ctrl+X`):

```
192.168.0.11  pc-lamp-1  fog1
192.168.0.12  pc-lamp-2  fog2
192.168.0.13  pc-lamp-3  cloud1
192.168.0.14  pc-lamp-4  fog3
192.168.0.15  pc-lamp-5  carga
192.168.0.16  pc-lamp-6  reserva
```

```bash
getent hosts fog1 pc-lamp-1     # os dois devem mostrar 192.168.0.11
```

O `carga` (pc-lamp-5) é o ponto de administração: dele saem os comandos para os outros PCs e as cópias de segurança (M1, passo 5). Uma chave SSH evita digitar a senha em cada `ssh` e `scp`. `carga$` (pc-lamp-5) gere a chave e copie-a para os demais. O `ssh-copy-id` pede a senha de cada PC uma única vez:

```bash
ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519
for h in fog1 fog2 cloud1 fog3 reserva; do ssh-copy-id "$h"; done
```

No M2 e no [fog3-k3d](fog3-k3d.md), os PCs de cluster trocam certificados e remote secrets entre si com `scp`. `fog1$` (pc-lamp-1), `fog2$` (pc-lamp-2) e `cloud1$` (pc-lamp-3) façam o mesmo para os outros PCs de cluster:

```bash
ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519
for h in fog1 fog2 cloud1 fog3; do ssh-copy-id "$h"; done    # copiar para o próprio PC é inofensivo
```

`carga$` (pc-lamp-5) confira que o acesso não pede mais senha:

```bash
ssh fog1 hostname        # responde pc-lamp-1 sem pedir senha
```

### 5. Relógios sincronizados

As figuras do artigo comparam **timestamps de PCs diferentes** (ex.: `REQUEST_FORWARD` no fog1 e `NEW_PR_RECEIVED` no fog2). Um erro de 50 ms no relógio vira um erro de 50 ms na medida.

O Ubuntu 26.04 já traz o **chrony** instalado e ativo. O `systemd-timesyncd` nem vem instalado. Mesmo assim, **a configuração padrão não sincroniza no laboratório**: os seis PCs estavam com `synchronized: no`, e o relógio do PC6 estava ~47 s adiantado (D28).

A causa é o **NTS**. As fontes padrão são os servidores da Canonical, definidos em `/etc/chrony/sources.d/ubuntu-ntp-pools.sources`, e todas exigem NTS. Antes do primeiro pacote NTP, o NTS negocia chaves pela porta TCP 4460, e a rede da instituição **recusa** essa porta. Em 2026-11-16, no PC1:

- `chronyc -n sources` mostrava todas as fontes com `^?` e `Reach 0`;
- `sudo chronyc -n authdata` mostrava `Atmp 14` e `Cook 0` em todas, ou seja, nenhuma negociação NTS deu certo;
- a conexão em `185.125.190.121:4460` voltava `Connection refused`, com a rota padrão pelo `eno1` funcionando.

Até a fonte que o roteador entrega por DHCP (`192.168.0.1`) aparece como NTS e nunca responde. Já o NTP comum (UDP 123) passa: num teste de 2026-11-14, servidores públicos (`time.google.com`, `a.st1.ntp.br`, `time.cloudflare.com`) responderam pelo cabo e pela Wi-Fi.

Confira se é o seu caso:

```bash
timedatectl | grep synchronized    # "no"
chronyc -n sources                 # todas as fontes "^?" com Reach 0
sudo chronyc -n authdata           # Cook 0 em todas
```

O `carga` sincroniza com servidores públicos, por NTP comum, e serve a hora aos outros PCs pelo cabo. Assim, todos têm a mesma referência a 1 salto de rede, o que importa mais para as medidas do que a hora exata.

Não edite o `/etc/chrony/chrony.conf`. A nossa configuração fica em arquivos próprios: as fontes em `sources.d/`, que só aceita `server`, `pool` e `peer`, e o resto em `conf.d/`. O chrony não aceita comentário no fim de uma linha de diretiva, então os comentários ficam em linhas próprias.

`todas$` (pc-lamp-1 a 6) desative as fontes NTS. O chrony só lê os arquivos `*.sources` desse diretório:

```bash
sudo mv /etc/chrony/sources.d/ubuntu-ntp-pools.sources{,.disabled}
```

`carga$` (pc-lamp-5):

```bash
sudo tee /etc/chrony/sources.d/microfog.sources <<'EOF'
server time.google.com iburst
server a.st1.ntp.br iburst
server time.cloudflare.com iburst
EOF
sudo tee /etc/chrony/conf.d/microfog.conf <<'EOF'
# Continua servindo a hora aos outros PCs se a internet cair
local stratum 10
allow 192.168.0.0/24
# Corrige o salto inicial (ex.: os 47 s do PC6) de uma vez
makestep 1 3
EOF
```

`demais$` (PCs 1–4 e 6):

```bash
echo 'server 192.168.0.15 iburst prefer' | sudo tee /etc/chrony/sources.d/microfog.sources
echo 'makestep 1 3' | sudo tee /etc/chrony/conf.d/microfog.conf
```

```bash
sudo systemctl restart chrony
chronyc -n sources     # no carga: um servidor público com '*'; nos demais: 192.168.0.15 com '*'
chronyc tracking       # "System time" abaixo de 1 ms
```

A fonte `192.168.0.1`, que vem do DHCP, continua na lista com `^?`. Isso é esperado: ela nunca responde e por isso não é escolhida.

O IP `172.19.176.12`, que é o DNS do roteador do switch, também responde NTP. Ele fica como alternativa, mas estava ~1 s fora dos servidores públicos no teste, então não é a fonte principal.

### 6. Docker Engine

O KinD e o k3d rodam cada nó do Kubernetes como um container, então o Docker é a base dos clusters. O `carga` também precisa dele para o build das imagens (M0).

`todas$` (pc-lamp-1 a 5). O `reserva` (pc-lamp-6) só precisa dele se virar registry ou cluster de monitoramento. Os comandos são os do guia oficial <https://docs.docker.com/engine/install/ubuntu/>. Primeiro, cadastre o repositório da Docker:

```bash
sudo apt install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
sudo apt update
apt-cache policy docker-ce     # "Candidate:" com uma versão = há pacote para o 26.04
```

Se houver pacote:

```bash
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

Se o `apt update` der erro no repositório da Docker, ou o `Candidate:` vier `(none)`, ainda não há pacotes para o Ubuntu 26.04. Nesse caso, remova o repositório, use o pacote da distribuição e registre isso no Registro de execução:

```bash
sudo rm /etc/apt/sources.list.d/docker.sources
sudo apt update
sudo apt install -y docker.io docker-buildx
```

Para rodar `docker`, `kind` e `k3d` sem `sudo`, ponha o usuário no grupo `docker`. O grupo só vale numa sessão nova:

```bash
sudo usermod -aG docker $USER
exit                              # entre de novo no ssh
docker run --rm hello-world
```

Mude as faixas de rede do Docker para longe da Wi-Fi (passo 3) e crie a rede `kind` numa faixa conhecida. O KinD reutiliza uma rede `kind` que já exista. Fixar a faixa agora permite que o M1 reserve um pedaço dela para o MetalLB:

```bash
echo '{ "default-address-pools": [{ "base": "10.200.0.0/16", "size": 24 }] }' \
  | sudo tee /etc/docker/daemon.json
sudo systemctl restart docker
docker network create kind --subnet 10.201.0.0/16    # nos PCs fog1, fog2 e cloud1
```

O M1 usa a faixa `10.201.255.x` desta rede no pool do MetalLB.

### 7. Ajustes do sistema para o KinD e o k3d

`clusters$` (pc-lamp-1 a 4: fog1, fog2, cloud1 e fog3). Clusters com vários nós-container esgotam os limites padrão de *inotify*: os pods ficam em `CrashLoopBackOff` com erro "too many open files".

```bash
cat <<'EOF' | sudo tee /etc/sysctl.d/99-kind.conf
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512
EOF
sudo sysctl --system
```

Confira o cgroup. O Ubuntu 26.04 usa só o cgroup v2:

```bash
stat -fc %T /sys/fs/cgroup     # esperado: cgroup2fs
```

### 8. Ferramentas

`todas$` (pc-lamp-1 a 5). Cada ferramenta tem um uso nas lições:

| Ferramenta | Para quê |
|---|---|
| `kubectl` | administrar os clusters (todas as lições a partir do M1) |
| `helm` | instalar o Loki e o Promtail ([gerador de carga](gerador-de-carga.md)) |
| `mc` | cliente do MinIO: criar buckets, replicação e upload dos metadados (M3) |
| `jq` | ler as saídas JSON do `kubectl` e das APIs do Control Engine |
| `hey` | gerador de carga HTTP (M7) |
| `git` | clonar o repositório MicroFog |

**As versões de `kind`, `istioctl` e `k3d` dependem do portão go/no-go do [M1](m1-clusters.md#portão-gono-go-de-versões)**: elas são instaladas lá, com a mesma versão em todos os PCs. O `k3d` só vai no `fog3` ([fog3-k3d.md](fog3-k3d.md)).

Pacotes do Ubuntu:

```bash
sudo apt install -y jq curl git hey
```

`kubectl`, pelo binário oficial. O `kubectl` só é garantido com clusters de até uma versão *minor* de diferença. Se o portão do M1 der GO (Kubernetes 1.24), troque `KUBECTL_VERSION` por `v1.24.17` e repita:

```bash
KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
sudo install -m 0755 kubectl /usr/local/bin/kubectl && rm kubectl
kubectl version --client
```

`helm`, pelo script oficial:

```bash
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

`mc`. O M3 fixa o servidor MinIO numa release de jan/2023, e um `mc` muito mais novo pode usar comandos que esse servidor não entende (a sintaxe de `mc replicate add`, por exemplo, mudou). Por isso, instale um `mc` da mesma época. O projeto open source do MinIO foi arquivado, e o `dl.min.io` responde `410 Gone` desde então (conferido em 2026-11-16). Os binários antigos continuam nas releases do GitHub:

```bash
MC_RELEASE=RELEASE.2023-01-28T20-29-38Z
curl -Lo mc "https://github.com/minio/mc/releases/download/${MC_RELEASE}/mc.linux-amd64.${MC_RELEASE}"
sudo install -m 0755 mc /usr/local/bin/mc && rm mc
mc --version
```

Clone o repositório em cada PC. Os manifestos e os metadados das aplicações usados nas lições estão nele. O clone vem do fork do grupo, e não do repositório dos autores, para que os PCs recebam as mudanças feitas aqui:

```bash
git clone https://github.com/pesquisa-lamp/MicroFog.git ~/MicroFog
```

## O que observar

- `ip route get 192.168.0.13` e `ip route get 1.1.1.1` saem pelo cabo (`eno1`).
- Com `sudo ip route del default dev eno1`, `ip route get 1.1.1.1` passa a sair pela Wi-Fi, e o `ping` entre os PCs continua funcionando. `sudo netplan apply` restaura.
- `hostname` mostra `pc-lamp-<n>`, e `ping fog1` e `ping pc-lamp-1` respondem do mesmo IP.
- `ssh fog1`, `ssh fog2`, `ssh cloud1` e `ssh fog3` funcionam a partir do `carga` sem senha.
- Desligar a Wi-Fi não afeta nada: nem o `ping` entre os PCs, nem a internet.
- `chronyc sources` mostra o `carga` (`192.168.0.15`) como fonte, marcado com `*`, nos outros cinco PCs.
- `docker info` mostra `Cgroup Version: 2`, e `docker network inspect kind` mostra a sub-rede `10.201.0.0/16`.

## Verifique seu entendimento

1. A Tabela 2 do artigo mostra o fog1 com 4 nós (3+4+5+3 = 15 vCPU) rodando numa VM de 16 vCPU. Se os 4 "nós" são containers no mesmo host, cada um deles enxerga quantas CPUs? *(Resposta no M1.)*
2. Os downloads passam pelo mesmo cabo que o tráfego entre clusters. Que medição seria distorcida por um `docker pull` no meio de um experimento, e como evitar?
3. Por que não usar a Wi-Fi para o tráfego entre clusters, já que ela também conecta todos os PCs?
4. O que quebraria se o roteador mudasse o IP do cabo de um PC depois do M2?
5. Por que o servidor NTP é o `carga`, e não um dos PCs de cluster?
6. Se a internet cair durante um experimento, o relógio do `carga` passa a derivar. Por que isso não estraga a comparação entre o `REQUEST_FORWARD` no fog1 e o `NEW_PR_RECEIVED` no fog2?

## Problemas comuns

| Sintoma | Causa provável | Diagnóstico |
|---|---|---|
| Sem internet depois do `netplan apply` | Roteador sem internet, ou sem rota `default` pelo `eno1` | `ip route`; `ping -c2 192.168.0.1` (gateway do roteador); troca manual para a Wi-Fi (passo 2) |
| Internet saindo pela Wi-Fi com o roteador funcionando | `route-metric` ausente ou invertido | `ip route`: o `eno1` deve ter `metric 100` |
| PC com IP do cabo fora da tabela | Reserva DHCP ausente ou com MAC errado | Lista de clientes DHCP no roteador |
| Containers sem acesso à internet | Faixa do Docker em conflito com a Wi-Fi | Passos 3 e 6; `docker network ls` e `ip route` |
| Wi-Fi não sobe | Falta `wpasupplicant` | `dpkg -l wpasupplicant` |
| `docker: permission denied` | O usuário ainda não está no grupo `docker` | Saia e entre de novo; `groups` |
| `chronyc sources` nos demais sem `*` em `192.168.0.15` | `allow` ausente no `carga`, ou o `carga` ainda não sincronizou | `chronyc sources -v`; no `carga`, `chronyc clients` |
| Todas as fontes `^?` com `Reach 0`, e `Cook 0` no `sudo chronyc -n authdata` | Fontes NTS padrão do Ubuntu ainda ativas; a rede recusa a porta 4460 | `ls /etc/chrony/sources.d/`: o `ubuntu-ntp-pools.sources` deve estar renomeado (passo 5) |
| `chronyc sources` no `carga` sem `*` | NTP bloqueado (não era o caso em 2026-11-14) ou DNS falhando | Teste com o IP direto do `time.google.com`, sem depender do DNS: `sudo chronyc add server 216.239.35.0 iburst` e, depois de ~30 s, `chronyc -n sources`. A fonte some no próximo `systemctl restart chrony` |

## Registro de execução

- Data:
- Nomes das interfaces, MACs do cabo e IPs reservados por PC:
- Faixa da Wi-Fi e se houve conflito:
- Desvio do relógio (`chronyc tracking`):
- Versão do Docker (`docker version`) e origem do pacote:
- Desvios do plano:
