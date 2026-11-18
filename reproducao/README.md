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

O trabalho roda direto nos 6 PCs do laboratório, ligados por um switch dedicado, com a arquitetura completa do artigo: quatro clusters (fog1, fog2, fog3 e cloud1), WAN emulada entre fog e cloud e um PC gerador de carga. A replicação fiel dos resultados (figuras da Seção 6) fica para depois e está só esboçada em [`experimentos/`](experimentos/README.md).

```
reproducao/
├── README.md                 ← você está aqui
├── decisoes.md               ← o que decidimos e por quê (leia antes de mudar algo)
├── licoes/                   ← as lições, na ordem da tabela abaixo
└── experimentos/             ← esboço dos experimentos E1–E5 do artigo
```

### Lições

| Marco | Lição | Você termina quando... | Conceito do artigo |
|---|---|---|---|
| — | [00 Preparar os PCs e a rede](licoes/00-preparar-pcs-e-rede.md) | 6 PCs Ubuntu com IP fixo e internet pelo cabo, Wi-Fi como redundância, relógios sincronizados, Docker e ferramentas | Fig. 1 (federação fog–cloud) |
| M0 | [Build das imagens](licoes/m0-build.md) | Imagens do CE e de 7 microserviços no GHCR, na organização do grupo | §3.3.1, §6.1.2 |
| M1 | [Clusters Kubernetes](licoes/m1-clusters.md) | fog1, fog2 e cloud1 (KinD) `Ready` com a topologia da Tabela 2, MetalLB e metrics-server | §2.3.2, §6.1.1 |
| M2 | [Malha Istio multi-cluster](licoes/m2-malha-istio.md) | Um `curl` no fog1 recebe respostas de pods do fog2 e do cloud1 | §2.3.3, §2.3.5 |
| M3 | [Data stores](licoes/m3-data-stores.md) | MinIO replicado e Redis primário/réplicas | §3.3.2, §4.1, §4.2, Fig. 6 |
| M4 | [Control Engine](licoes/m4-control-engine.md) | CE rodando nos 3 clusters e respondendo entre clusters | §3.3.1, §4.3, Fig. 7–10 |
| M5 | [Placement local](licoes/m5-placement-local.md) | PR do hcApp implantado e respondendo, sem forwarding | §3.4 (fluxo do PR), Fig. 2 |
| M6 | [Placement distribuído](licoes/m6-placement-distribuido.md) | PR do app2 encaminhado entre clusters, app funcionando | §6.1.3 (V2), Fig. 4, Fig. 12 |
| M7 | [Weighted Round Robin](licoes/m7-wrr.md) | Kiali mostra o tráfego dividido na proporção dos recursos | §6.2.2, Fig. 15–16 |
| — | [WAN emulada](licoes/wan-netem.md) | Atraso entre fog e cloud com `tc netem`; M6 refeito com a WAN | §6.1.1, Fig. 11, 12, 17 |
| — | [fog3 com k3d](licoes/fog3-k3d.md) | O quarto cluster (k3s), que o repositório não traz, integrado à malha e aos CEs | §6.1.1, Fig. 14 |
| — | [Gerador de carga e logs](licoes/gerador-de-carga.md) | Kubeconfigs no PC `carga`, scripts de PR, Grafana + Loki | §6.1, Fig. 11–14 |
| M8 | [Modo centralizado](licoes/m8-centralizado.md) | CE primário no cloud1 executando o V3 | §3.3.1, Fig. 4, Fig. 13 |
| M9 | [Failover dos data stores](licoes/m9-failover.md) | Derrubar MinIO/Redis e observar o failover por localidade | §4.1, §4.2, Fig. 11 |

Do M0 ao M7, cada mecanismo central (placement, forwarding, deploy cruzado, load balancing) roda pelo menos uma vez, com três clusters. As lições seguintes completam a arquitetura do artigo.

## Convenções

- **Onde rodar cada comando**: o prompt indica o PC pelo papel. `fog1$` é o PC do fog1, `cloud1$` o do cloud1, `carga$` o gerador de carga, `todas$` significa repetir em cada PC e `clusters$` em cada PC de cluster (fog1, fog2, cloud1 e, depois, fog3). Os hostnames são `pc-lamp-1` a `pc-lamp-6`, e os papéis são apelidos no `/etc/hosts` (tabela em [00](licoes/00-preparar-pcs-e-rede.md)).
- **IPs**: cada PC tem um IP fixo no cabo, `192.168.0.11` (fog1), `.12` (fog2), `.13` (cloud1), `.14` (fog3), `.15` (carga) e `.16` (reserva). É o endereço que os guias originais chamam de `<PUBLIC_IP_OF_THE_VM>`. Se a faixa do switch mudar (00, passo 3), troque `192.168.0.` em todas as lições.
- **Contextos Kubernetes**: cada cluster é administrado **a partir do seu próprio PC**. O KinD cria o contexto `kind-<cluster>` (ex.: `kind-fog1`) e o k3d, `k3d-fog3`. Para trocar informações entre clusters (secrets, certificados), copie arquivos via `scp`. A partir da lição do [gerador de carga](licoes/gerador-de-carga.md), o `carga` também administra todos.
- **Origem das imagens**: a variável `IMAGE_SOURCE` escolhe entre `local` (imagens compiladas por nós, no GHCR da organização do grupo) e `upstream` (imagens dos autores, no Docker Hub). Veja [M0](licoes/m0-build.md#origem-das-imagens-image_source).
- **Versões**: definidas no portão go/no-go do [M1](licoes/m1-clusters.md#portão-gono-go-de-versões) e registradas em [`decisoes.md`](decisoes.md).

## Como estudar cada lição

Toda lição segue o mesmo roteiro:

1. **Objetivo**: o que você terá no fim.
2. **Conceitos**: a teoria mínima, com a seção correspondente do artigo.
3. **Passos**: comandos com explicação.
4. **O que observar**: a saída esperada e o que ela significa.
5. **Verifique seu entendimento**: perguntas e mini-experimentos. Tente **prever** o resultado antes de rodar.
6. **Problemas comuns**: sintoma → causa provável → diagnóstico.
7. **Registro de execução**: para preencher.

### Pontos de retorno

Errar e voltar faz parte do aprendizado. Um cluster KinD se recria em poucos minutos (`kind delete cluster --name fog1` e `kind create cluster --config ...`), então o ponto de retorno são os **arquivos de configuração**, não o estado do PC. Ao fim de cada marco, copie para o `carga` os diretórios `~/clusters`, `~/ce` e `~/certs` de cada PC (`scp -r fog1:clusters ~/backup/fog1/` etc.). O `~/certs` do fog1 guarda a CA raiz da malha (M2): se ele se perder, é preciso refazer os certificados dos quatro clusters.
