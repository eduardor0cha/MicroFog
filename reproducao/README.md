# Reprodução do MicroFog — plano de execução

Plano para colocar o MicroFog para funcionar, aprendendo o framework no caminho, a partir do artigo:

> Pallewatta, Kostakos, Buyya. *MicroFog: A framework for scalable placement of microservices-based IoT applications in federated Fog environments.* Journal of Systems and Software, 209 (2024) 111910.

O [PDF incluído](pallewatta2024-microfog.pdf) é a versão publicada do artigo, © 2023 The Authors, publicado pela Elsevier Inc. sob a licença [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). DOI: [10.1016/j.jss.2023.111910](https://doi.org/10.1016/j.jss.2023.111910). Distribuído sem alterações.

**Status:** plano ainda não executado. Os comandos foram escritos a partir do código e dos guias do repositório (`Prototype_Setup/docs/*.pdf`), mas ainda não rodaram no nosso ambiente. Cada lição termina com um **Registro de execução**: preencha-o com o que funcionou, o que mudou e as versões usadas. É esse registro que transforma o plano em procedimento reproduzível.

## Para quem é

Para quem já leu o artigo mas talvez não o tenha entendido por inteiro.

**Pré-requisitos:** Linux e shell no nível básico (ssh, editar arquivos, systemd) e Docker no nível básico (imagem, container, `docker run`, `docker ps`). Kubernetes e Istio **não** são pré-requisitos: cada lição apresenta o que for preciso, quando for preciso.

Para quem não tem os pré-requisitos:
- Linux: <https://ubuntu.com/tutorials/command-line-for-beginners>
- Docker: <https://docs.docker.com/get-started/>

## Estrutura

O trabalho tem duas fases. A **Fase A** é um ensaio em 3 VMs num único desktop. A **Fase B** repete o ensaio nos 6 PCs do laboratório e completa a arquitetura do artigo. A replicação fiel dos resultados (figuras da Seção 6) fica para depois e está só esboçada em [`experimentos/`](experimentos/README.md).

```
reproducao/
├── README.md                 ← você está aqui
├── decisoes.md               ← o que decidimos e por quê (leia antes de mudar algo)
├── fase-a-vm/                ← 3 VMs (fog1, fog2, cloud1) num desktop Windows
├── fase-b-pcs/               ← 6 PCs físicos num switch dedicado
└── experimentos/             ← esboço dos experimentos E1–E5 do artigo
```

### Fase A — VMs (ensaio)

| Marco | Lição | Você termina quando... | Conceito do artigo |
|---|---|---|---|
| — | [00 Preparar as VMs](fase-a-vm/00-preparar-vms.md) | 3 VMs Ubuntu com IP fixo, Docker e ferramentas | Fig. 1 (federação fog–cloud) |
| M0 | [Build das imagens](fase-a-vm/m0-build.md) | Imagens do CE e de 7 microserviços no GHCR | §3.3.1, §6.1.2 |
| M1 | [Clusters Kubernetes](fase-a-vm/m1-clusters.md) | 3 clusters KinD `Ready`, com MetalLB e metrics-server | §2.3.2, §6.1.1 |
| M2 | [Malha Istio multi-cluster](fase-a-vm/m2-malha-istio.md) | Um `curl` no fog1 recebe respostas de pods do fog2 e do cloud1 | §2.3.3, §2.3.5 |
| M3 | [Data stores](fase-a-vm/m3-data-stores.md) | MinIO replicado e Redis primário/réplicas | §3.3.2, §4.1, §4.2, Fig. 6 |
| M4 | [Control Engine](fase-a-vm/m4-control-engine.md) | CE rodando nos 3 clusters e respondendo entre clusters | §3.3.1, §4.3, Fig. 7–10 |
| M5 | [Placement local](fase-a-vm/m5-placement-local.md) | PR do hcApp implantado no cloud1 e respondendo | §3.4 (fluxo do PR), Fig. 2 |
| M6 | [Placement distribuído](fase-a-vm/m6-placement-distribuido.md) | PR do app2 encaminhado entre clusters, app funcionando | §6.1.3 (V2), Fig. 4, Fig. 12 |
| M7 | [Weighted Round Robin](fase-a-vm/m7-wrr.md) | Kiali mostra o tráfego dividido na proporção dos recursos | §6.2.2, Fig. 15–16 |

A Fase A termina no **M7**.

### Fase B — PCs

| Lição | Conteúdo |
|---|---|
| [00 Preparar os PCs e a rede](fase-b-pcs/00-preparar-pcs-e-rede.md) | Ubuntu, rede com duas interfaces (cabo + Wi-Fi), relógio, papéis de cada PC |
| [M1–M7 nos PCs](fase-b-pcs/m1-m7-nos-pcs.md) | O que muda em relação à Fase A (topologia completa da Tabela 2) |
| [fog3 com k3d](fase-b-pcs/fog3-k3d.md) | O quarto cluster, com k3s, que o repositório não traz |
| [WAN emulada](fase-b-pcs/wan-netem.md) | Atraso entre fog e cloud com `tc netem` |
| [Gerador de carga e logs](fase-b-pcs/gerador-de-carga.md) | PC dedicado para PRs, carga HTTP, Grafana + Loki |
| [M8 Modo centralizado](fase-b-pcs/m8-centralizado.md) | CE primário no cloud1 executando o V3 |
| [M9 Failover dos data stores](fase-b-pcs/m9-failover.md) | Derrubar MinIO/Redis e observar o failover por localidade |

## Convenções

- **Onde rodar cada comando**: o prompt indica a máquina. `fog1$` é a VM/PC do fog1, `cloud1$` a do cloud1, `todas$` significa repetir em cada uma, `win>` é o PowerShell do Windows e `carga$` o PC gerador de carga. Na Fase B, os PCs se chamam `pc-lamp-1` a `pc-lamp-6`, e os papéis são apelidos no `/etc/hosts` (tabela em [00-preparar-pcs-e-rede.md](fase-b-pcs/00-preparar-pcs-e-rede.md)).
- **Placeholders**: `<IP_FOG1>`, `<IP_FOG2>`, `<IP_CLOUD1>` (e `<IP_FOG3>` na Fase B) são os IPs fixos de cada host. Os valores reais ficam anotados em `00-preparar-*.md`.
- **Contextos Kubernetes**: cada cluster é administrado **a partir do seu próprio host**. O KinD cria o contexto `kind-<cluster>` (ex.: `kind-fog1`). Para trocar informações entre clusters (secrets, certificados), copie arquivos via `scp`.
- **Origem das imagens**: a variável `IMAGE_SOURCE` escolhe entre `local` (imagens compiladas por nós, no GHCR) e `upstream` (imagens dos autores, no Docker Hub). Veja [M0](fase-a-vm/m0-build.md#origem-das-imagens-image_source).
- **Versões**: definidas no portão go/no-go do [M1](fase-a-vm/m1-clusters.md#portão-gono-go-de-versões) e registradas em [`decisoes.md`](decisoes.md).

## Como estudar cada lição

Toda lição segue o mesmo roteiro:

1. **Objetivo**: o que você terá no fim.
2. **Conceitos**: a teoria mínima, com a seção correspondente do artigo.
3. **Passos**: comandos com explicação.
4. **O que observar**: a saída esperada e o que ela significa.
5. **Verifique seu entendimento**: perguntas e mini-experimentos. Tente **prever** o resultado antes de rodar.
6. **Problemas comuns**: sintoma → causa provável → diagnóstico.
7. **Registro de execução**: para preencher.

Antes de cada marco, tire um **snapshot das VMs** (checkpoint no Hyper-V, snapshot no VirtualBox). Errar e voltar faz parte do aprendizado.
