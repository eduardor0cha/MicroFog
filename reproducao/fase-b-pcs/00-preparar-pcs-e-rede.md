# 00 — Preparar os PCs e a rede

## Objetivo

Seis PCs com Ubuntu Server 26.04.1, cada um com um papel definido. Todos falam entre si pelo **switch** (cabo, IP fixo por reserva DHCP no roteador do switch) e acessam a internet pela **Wi-Fi**, com relógios sincronizados.

Pré-requisito: Fase A concluída (M7).

## Conceitos

### Papéis (decisão D18)

| PC | RAM | Papel | Hostname | IP no cabo |
|---|---|---|---|---|
| PC1 | 24 GB | cluster **fog1** (KinD, 4 nós) | `pc-lamp-1` | `192.168.0.11` |
| PC2 | 24 GB | cluster **fog2** (KinD, 5 nós) | `pc-lamp-2` | `192.168.0.12` |
| PC3 | 24 GB | cluster **cloud1** (KinD, 2 nós) + WAN emulada | `pc-lamp-3` | `192.168.0.13` |
| PC4 | 16 GB | cluster **fog3** (k3d, 3 nós) | `pc-lamp-4` | `192.168.0.14` |
| PC5 | 16 GB | **gerador de carga**, administração, servidor NTP | `pc-lamp-5` | `192.168.0.15` |
| PC6 | 12 GB | **reserva** / monitoramento central / registry local (plano B, D16) | `pc-lamp-6` | `192.168.0.16` |

Levantamento de 2026-11-14:

- **CPU:** todos têm um Intel Core i5-4570, de 4ª geração, com 4 núcleos e sem hyper-threading.
- **Disco:** todos usam **disco rígido mecânico** (HDD). O volume LVM da raiz tem 98 GB, num disco de 1 TB nos PCs 1–2 e de 500 GB nos PCs 3–6.
- **Sistema:** Ubuntu 26.04.1, kernel 7.0 e cgroup v2.
- **Memória utilizável** (`free -g`): ~22 GiB nos PCs 1–3, ~15 GiB nos PCs 4–5 e ~11 GiB no PC6.

A Tabela 2 soma 54 vCPU e 122 GB; temos 24 núcleos e ~107 GiB utilizáveis. Os tamanhos lógicos dos nós ficam em [m1-m7-nos-pcs.md](m1-m7-nos-pcs.md) (questão em aberto A2).

### Duas interfaces (decisão D19)

```
   roteador ── switch (192.168.0.0/24, reserva DHCP por MAC)
   ┌──────┬──────┬──────┬──────┬──────┬──────┐
  fog1   fog2  cloud1  fog3  carga  reserva      ← tráfego MicroFog: 80, 6443, 15443, PRs
  (.11)  (.12)  (.13)  (.14)  (.15)  (.16)
   │      │      │      │      │      │
   └──────┴──────┴──────┴──────┴──────┴──── Wi-Fi WPA2 → internet (rota padrão)
```

- O **IP do cabo** é o "IP público da VM" dos guias: vai para o certificado do API server, o MetalLB, o `loadBalancerIP`, o `meshNetworks` e os remote secrets.
- A **Wi-Fi** só serve para `apt`, pull de imagens e GHCR. Ela **não pode** ser a rota entre os PCs.
- O **roteador do switch** também dá internet, mas os PCs ignoram o gateway e o DNS que ele anuncia: a rota padrão fica na Wi-Fi. Assim, downloads grandes não disputam o cabo com o tráfego que será medido. Se a Wi-Fi do laboratório falhar, dá para usar o roteador como plano B: basta tirar o `dhcp4-overrides` do passo 2.

## Passos

### 1. Instalar o Ubuntu

Ubuntu Server 26.04.1 com OpenSSH. **Configure a Wi-Fi já no instalador**: o Ubuntu Server precisa do `wpasupplicant` para Wi-Fi, e sem rede não dá para instalá-lo depois. Se o instalador não detectar a placa Wi-Fi, use o cabo: o roteador do switch também dá internet.

Na BIOS: desative suspensão e hibernação, e ative "power on after AC loss" se existir.

### 2. Reserva DHCP e netplan com duas interfaces

No roteador do switch, reserve para cada PC o IP da tabela de papéis, associado ao MAC da interface cabeada (`ip -br link` mostra o MAC). O IP do cabo vai para certificados e configurações do Istio (D12), então a reserva **não pode** mudar.

`todas$` (troque os nomes das interfaces, conforme `ip -br link`). A cabeada é `eno1` em todos os PCs. A Wi-Fi é `wlp2s0`, exceto no **PC2**, onde é `wlp3s0`. O arquivo a editar é o `/etc/netplan/00-installer-config.yaml`:

```yaml
network:
  version: 2
  ethernets:
    eno1:
      dhcp4: true
      dhcp4-overrides:
        use-routes: false     # ignora o gateway do roteador: a rota padrão fica na Wi-Fi
        use-dns: false
  wifis:
    wlp2s0:
      dhcp4: true
      access-points:
        "NOME_DA_REDE":
          password: "SENHA"
```

```bash
sudo netplan apply
ip -4 addr show eno1      # deve mostrar o IP reservado (ex.: 192.168.0.11 no PC1)
ip route                  # a única rota "default" deve sair pela Wi-Fi
ping -c2 192.168.0.12      # deve sair pelo eno1
ip route get 192.168.0.12
```

### 3. Conferir conflitos de faixa de IP

O Docker usa `172.17.0.0/16` e a rede `kind` usa `172.18.0.0/16`. Veja que faixa a Wi-Fi entrega:

```bash
ip -4 addr show wlp2s0
```

Se ela cair em `172.16.0.0/12`, mude as faixas do Docker **antes** de criar os clusters. **No laboratório é o caso**: a Wi-Fi entrega `172.23.64.0/20`, e o DNS do roteador do switch fica em `172.19.176.12`. As redes que o Docker cria por padrão podem cair por cima dessas faixas:

```bash
echo '{ "default-address-pools": [{ "base": "10.200.0.0/16", "size": 24 }] }' \
  | sudo tee /etc/docker/daemon.json
sudo systemctl restart docker
docker network create kind --subnet 10.201.0.0/16   # o KinD reutiliza esta rede
```

Nesse caso, ajuste também a faixa `172.18.255.x` dos pools do MetalLB para a nova sub-rede.

Confira também se a Wi-Fi **não** entrega endereços em `192.168.0.0/24`, a faixa do cabo. Ela é o padrão de muitos roteadores domésticos. Se coincidir, haverá duas rotas para a mesma sub-rede, e o tráfego entre os PCs pode sair pela Wi-Fi (ou não chegar). Nesse caso, mude a faixa do roteador do switch (que está sob nosso controle) e troque `192.168.0.` em todas as lições da Fase B.

### 4. Nomes, SSH e administração

O hostname de cada PC é `pc-lamp-<n>`, com `<n>` igual ao número do PC (`sudo hostnamectl set-hostname pc-lamp-1` no PC1, e assim por diante). As lições se referem aos PCs pelo **papel** (`fog1$`, `carga$`, `scp fog1:...`), então o `/etc/hosts` de todos registra o hostname e o papel como apelido:

```
192.168.0.11  pc-lamp-1  fog1
192.168.0.12  pc-lamp-2  fog2
192.168.0.13  pc-lamp-3  cloud1
192.168.0.14  pc-lamp-4  fog3
192.168.0.15  pc-lamp-5  carga
192.168.0.16  pc-lamp-6  reserva
```

No PC `carga` (pc-lamp-5), gere uma chave SSH e copie-a para os demais (`ssh-copy-id`). O `carga` vira o ponto de administração.

### 5. Relógios sincronizados

As figuras do artigo comparam **timestamps de PCs diferentes** (ex.: `REQUEST_FORWARD` no fog1 e `NEW_PR_RECEIVED` no fog2). Um erro de 50 ms no relógio vira um erro de 50 ms na medida.

A rede da instituição **não bloqueia NTP**. Num teste de 2026-11-14, servidores públicos (`time.google.com`, `a.st1.ntp.br`, `time.cloudflare.com`) responderam pelo cabo e pela Wi-Fi. Mesmo assim, os seis PCs estavam com `synchronized: no`, e o relógio do PC6 estava ~47 s adiantado. O `systemd-timesyncd` padrão não estava funcionando, e o chrony o substitui.

O `carga` sincroniza com a internet e serve a hora aos outros PCs pelo cabo. Assim, todos têm a mesma referência a 1 salto de rede, o que importa mais para as medidas do que a hora exata.

`todas$` instale o chrony. Ele substitui o `systemd-timesyncd`:

```bash
sudo apt install -y chrony
```

`carga$` em `/etc/chrony/chrony.conf`, comente as linhas `pool`/`server` existentes e acrescente:

```
server time.google.com iburst
server a.st1.ntp.br iburst
server time.cloudflare.com iburst
local stratum 10          # continua servindo a hora se a internet cair
allow 192.168.0.0/24
makestep 1 3              # corrige o salto inicial (ex.: os 47 s do PC6) de uma vez
```

`demais$` (PCs 1–4 e 6) em `/etc/chrony/chrony.conf`, comente as linhas `pool`/`server` e acrescente:

```
server 192.168.0.15 iburst prefer
makestep 1 3
```

```bash
sudo systemctl restart chrony
chronyc sources        # no carga: um servidor público com '*'; nos demais: 192.168.0.15 com '*'
chronyc tracking       # "System time" abaixo de 1 ms
```

O IP `172.19.176.12`, que é o DNS do roteador do switch, também responde NTP. Ele fica como alternativa, mas estava ~1 s fora dos servidores públicos no teste, então não é a fonte principal.

### 6. Docker, ferramentas e ajustes

Iguais aos passos 4–6 do [00 da Fase A](../fase-a-vm/00-preparar-vms.md), com as versões registradas no portão do M1 (`decisoes.md`, D13). No `fog3`, instale também o `k3d` ([fog3-k3d.md](fog3-k3d.md)).

## O que observar

- `ip route get 192.168.0.13` sai pelo cabo; `ip route get 1.1.1.1` sai pela Wi-Fi.
- `hostname` mostra `pc-lamp-<n>`, e `ping fog1` e `ping pc-lamp-1` respondem do mesmo IP.
- Desligar a Wi-Fi não afeta `ping` entre os PCs.
- `chronyc sources` mostra o `carga` (`192.168.0.15`) como fonte, marcado com `*`, nos outros cinco PCs.

## Verifique seu entendimento

1. O roteador do switch também tem internet. O que mudaria nas medições se a rota padrão saísse pelo cabo?
2. Por que não usar a Wi-Fi para o tráfego entre clusters, já que ela também conecta todos os PCs?
3. Por que o servidor NTP é o `carga`, e não um dos PCs de cluster?
4. Se a internet cair durante um experimento, o relógio do `carga` passa a derivar. Por que isso não estraga a comparação entre o `REQUEST_FORWARD` no fog1 e o `NEW_PR_RECEIVED` no fog2?

## Problemas comuns

| Sintoma | Causa provável | Diagnóstico |
|---|---|---|
| Sem internet depois do `netplan apply` | Wi-Fi não conectou | `ip route`; deve haver uma rota `default` pela Wi-Fi |
| Duas rotas `default` | Faltou `dhcp4-overrides` no cabo | `ip route` |
| PC com IP do cabo fora da tabela | Reserva DHCP ausente ou com MAC errado | Lista de clientes DHCP no roteador |
| Containers sem acesso à internet | Faixa do Docker em conflito com a Wi-Fi | Passo 3 |
| Wi-Fi não sobe | Falta `wpasupplicant` | `dpkg -l wpasupplicant` |
| `chronyc sources` nos demais sem `*` em `192.168.0.15` | `allow` ausente no `carga`, ou o `carga` ainda não sincronizou | `chronyc sources -v`; no `carga`, `chronyc clients` |
| `chronyc sources` no `carga` sem `*` | NTP bloqueado (não era o caso em 2026-11-14) ou DNS falhando | Teste com o IP direto, por exemplo `server 216.239.35.0 iburst` |

## Registro de execução

- Data:
- Nomes das interfaces, MACs do cabo e IPs reservados por PC:
- Faixa da Wi-Fi e se houve conflito:
- Desvio do relógio (`chronyc tracking`):
