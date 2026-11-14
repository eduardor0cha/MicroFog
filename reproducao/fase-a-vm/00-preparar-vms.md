# 00 — Preparar as VMs

## Objetivo

Ter três VMs Ubuntu Server 26.04.1, chamadas `fog1`, `fog2` e `cloud1`, cada uma com IP fixo na rede doméstica, Docker e as ferramentas de linha de comando que as próximas lições usam.

## Conceitos

### Por que três VMs se o artigo fala em "clusters"?

No artigo (Fig. 1 e §6.1.1), cada **cluster** é um cluster Kubernetes independente: fog1, fog2, fog3 e cloud1. Cada um fica numa rede diferente e é exposto ao mundo por um load balancer. Os autores criaram **uma VM por cluster** e, dentro de cada VM, um cluster **KinD**.

O KinD (*Kubernetes in Docker*) roda cada **nó** do Kubernetes como um **container Docker**. É assim que uma única VM de 16 vCPU vira um cluster de 4 "nós" heterogêneos na Tabela 2. Vamos fazer o mesmo, em escala menor:

```
Desktop Windows (Ryzen 7, 32 GB)
├── VM fog1   (4 vCPU, 8 GB) ── Docker ── cluster KinD "fog1"   (3 nós-container)
├── VM fog2   (4 vCPU, 8 GB) ── Docker ── cluster KinD "fog2"   (3 nós-container)
└── VM cloud1 (4 vCPU, 8 GB) ── Docker ── cluster KinD "cloud1" (2 nós-container)
```

### O "IP público da VM"

Os guias originais falam em `<PUBLIC_IP_OF_THE_VM>`: é o endereço pelo qual **os outros clusters** alcançam este. No nosso caso, é o IP de cada VM na rede doméstica. Ele vai ser gravado em vários lugares (certificado, MetalLB, Istio), e por isso **precisa ser fixo**.

## Passos

### 1. Escolher o hipervisor

`win>` Rode `winver`. Se aparecer **Pro, Enterprise ou Education**, use o **Hyper-V**, que é gratuito e vem com o Windows. Em PowerShell como administrador:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All
```

Depois de reiniciar, no Hyper-V Manager, crie um **Virtual Switch Manager → External** ligado à placa de rede **cabeada**, se houver. Esse é o modo bridged: as VMs recebem IPs da rede doméstica, como se fossem computadores físicos.

Se for o Windows **Home**, use o VirtualBox com **Rede → Placa em modo Bridge**.

### 2. Criar as três VMs

| Item | Valor | Por quê |
|---|---|---|
| vCPU | 4 | 12 das 16 threads do Ryzen. Sobram 4 para o Windows |
| RAM | 8 GB, **fixa** | No Hyper-V, **desative a Memória Dinâmica**. Os nós KinD leem a memória da VM para calcular o *allocatable*, e esse número precisa ser estável |
| Disco | 60 GB, dinâmico | Imagens `kindest/node`, Istio e aplicações |
| Geração (Hyper-V) | 2, com Secure Boot no modelo "Microsoft UEFI Certificate Authority" | É o modelo que aceita o boot do Ubuntu |
| Rede | Switch External / Bridge | Cada VM com IP próprio na LAN |

Instale o Ubuntu Server 26.04.1 marcando **OpenSSH server**. **Não** instale o Docker pelo instalador (que usa snap): vamos usar o pacote apt.

Dica: instale **uma** VM até o fim do passo 5 e depois clone-a duas vezes (mudando hostname e IP). Isso economiza tempo e garante VMs idênticas.

### 3. IP fixo e nomes

Escolha três IPs **fora da faixa do DHCP** do roteador (ou faça reserva de DHCP pelo MAC da VM). Anote aqui:

| VM | Hostname | IP |
|---|---|---|
| fog1 | `fog1` | `<IP_FOG1>` = ________ |
| fog2 | `fog2` | `<IP_FOG2>` = ________ |
| cloud1 | `cloud1` | `<IP_CLOUD1>` = ________ |

`todas$` Configure `/etc/netplan/50-cloud-init.yaml` (troque a interface, o IP e o gateway pelos seus):

```yaml
network:
  version: 2
  ethernets:
    eth0:                      # confira o nome com: ip -br link
      dhcp4: false
      addresses: [<IP_DESTA_VM>/24]
      routes:
        - to: default
          via: <IP_DO_ROTEADOR>
      nameservers:
        addresses: [1.1.1.1, 8.8.8.8]
```

```bash
sudo netplan apply
sudo hostnamectl set-hostname fog1      # fog2 / cloud1 nas outras
```

Acrescente as três VMs ao `/etc/hosts` de cada uma:

```
<IP_FOG1>    fog1
<IP_FOG2>    fog2
<IP_CLOUD1>  cloud1
```

### 4. Docker Engine

`todas$` Siga o guia oficial <https://docs.docker.com/engine/install/ubuntu/>. Se o repositório da Docker ainda não tiver pacotes para a versão do Ubuntu, use o pacote da distribuição (`sudo apt install docker.io`) e registre isso no Registro de execução.

```bash
sudo usermod -aG docker $USER     # saia e entre de novo no ssh
docker run --rm hello-world
```

### 5. Ajustes do sistema para o KinD

Clusters KinD com vários nós esgotam os limites padrão de *inotify*: os pods ficam em `CrashLoopBackOff` com erro "too many open files".

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

### 6. Ferramentas

`todas$` Instale `kubectl`, `kind`, `istioctl`, `helm`, `mc` (cliente do MinIO), `jq` e `hey` (gerador de carga HTTP). **As versões de `kind` e `istioctl` dependem do portão go/no-go do [M1](m1-clusters.md#portão-gono-go-de-versões)**: instale-as só quando chegar lá.

```bash
sudo apt install -y jq curl git hey
# kubectl: https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/
# helm:    https://helm.sh/docs/intro/install/
# mc:      https://min.io/docs/minio/linux/reference/minio-mc.html
```

Clone o repositório em cada VM:

```bash
git clone https://github.com/Cloudslab/MicroFog.git ~/MicroFog
```

### 7. Snapshot

Desligue as VMs e tire um snapshot chamado **`base`**. É o ponto de retorno se o M1 der errado.

## O que observar

- `ssh fog1`, `ssh fog2` e `ssh cloud1` funcionam a partir do Windows (ou do Mac).
- Em cada VM, `ping fog1 fog2 cloud1` responde.
- `docker info` mostra `Cgroup Version: 2`.

## Verifique seu entendimento

1. A Tabela 2 do artigo mostra o fog1 com 4 nós (3+4+5+3 = 15 vCPU) rodando numa VM de 16 vCPU. Se os 4 "nós" são containers na mesma VM, cada um deles enxerga quantas CPUs? *(Resposta no M1.)*
2. Por que a Memória Dinâmica do Hyper-V atrapalharia o MicroFog? Pense em quem lê a capacidade dos nós para decidir o placement (§3.3.1).
3. O que quebraria se o roteador mudasse o IP de uma VM depois do M2?

## Problemas comuns

| Sintoma | Causa provável | Diagnóstico |
|---|---|---|
| VM sem rede no Hyper-V | Switch External ligado à placa errada (ou à Wi-Fi) | Hyper-V Manager → Virtual Switch Manager |
| VirtualBox muito lento | Hyper-V/WSL2 ativo no Windows | `win> bcdedit /enum` e procure `hypervisorlaunchtype` |
| `docker: permission denied` | O usuário ainda não está no grupo `docker` | Saia e entre de novo; `groups` |

## Registro de execução

- Data:
- Hipervisor e versão:
- IPs usados:
- Versão do Docker (`docker version`):
- Desvios do plano:
