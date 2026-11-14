# M1–M7 nos PCs

## Objetivo

Refazer os marcos M1 a M7 da Fase A nos PCs, agora com a **topologia de nós da Tabela 2** (fog1: 4 nós, fog2: 5, cloud1: 2). Esta lição lista **só o que muda**. Os conceitos e passos estão nas lições da Fase A.

Faça primeiro com os três clusters da Fase A (fog1, fog2, cloud1). O fog3 entra depois, em [fog3-k3d.md](fog3-k3d.md).

## O que muda

| Marco | Fase A | Fase B |
|---|---|---|
| M0 | Build numa VM | **Não refazer**: as imagens já estão no GHCR. Só rebuild se o código mudou |
| M1 | 3/3/2 nós, VMs de 4 vCPU / 8 GB | **4/5/2 nós**, PCs de 4 núcleos / 24 GB. Tamanhos na seção abaixo |
| M1 | IPs da rede doméstica | `192.168.0.11–13` (cabo) |
| M2 | Remote secrets entre 3 clusters (6) | Idem; com o fog3, serão 4 clusters (12 secrets) |
| M3 | — | Igual |
| M4 | VS do CE adaptado (rota só por cabeçalho), `forwardpolicy = to_rand_fog` | Reaproveite os arquivos validados na Fase A |
| M5 | Entrada pelo cloud1 (os fogs eram pequenos demais) | Com nós maiores, refaça **também** com entrada no fog1 |
| M6/M7 | Placement sem WAN | Refaça **depois** de ativar a [WAN emulada](wan-netem.md): agora a latência fog × cloud fica visível |
| Admin | Cada VM administra o seu cluster | O PC `carga` pode concentrar os kubeconfigs (ver [gerador-de-carga.md](gerador-de-carga.md)) |

## Tamanhos lógicos dos nós (questão em aberto A2)

Restrições:
- **Nenhum nó KinD pode ter allocatable maior que o PC** (4 núcleos). A Tabela 2 tem nós de 5 e de 8 vCPU.
- A **memória** somada dos nós de um cluster deve caber nos 24 GB reais, porque memória não se compartilha como CPU: um *overcommit* termina em OOM.

**Proposta inicial: Tabela 2 × 0,5, em CPU e em memória.**

| Cluster | Nó (Tabela 2) | Tabela 2 | Alvo (× 0,5) |
|---|---|---|---|
| fog1 | control-plane / worker / worker2 / worker3 | 3/6, 4/9, 5/16, 3/8 | 1,5/3, 2/4,5, 2,5/8, 1,5/4 |
| fog2 | control-plane / worker / worker2 / worker3 / worker4 | 3/6, 3/9, 2/6, 4/12, 4/8 | 1,5/3, 1,5/4,5, 1/3, 2/6, 2/4 |
| fog3 | server / agent-0 / agent-1 | 3/6, 2/4, 2/4 | 1,5/3, 1/2, 1/2 |
| cloud1 | control-plane / worker | 8/14, 8/14 | 4/7, 4/7 |

(valores em vCPU / GB)

- Cada nó cabe no PC (≤ 4 núcleos), e a memória somada cabe em 24 GB (fog1: 19,5; fog2: 20,5; cloud1: 14; fog3: 7 de 16).
- A CPU somada passa do real (fog1: 7,5 lógicos em 4 núcleos). Isso é *overcommit* de contabilidade, aceitável para "ver funcionando", mas que **distorce latências** quando a carga é alta.
- Os requisitos das aplicações (hcm2 = 1 CPU etc.) **não** foram reduzidos. A relação aplicação/infraestrutura é o dobro da do artigo, e o placement vai diferir da Tabela 3. Para a replicação fiel, considere também multiplicar por 0,5 os requisitos em `metadata/*.java` (é preciso recompilar o CE, M0).

Para calcular o `system-reserved` de cada nó:

```bash
fog1$ kubectl describe node fog1-worker | grep -A2 Capacity    # capacidade real vista pelo nó
# system-reserved = capacidade − alvo − ~100Mi (limiar de despejo)
```

Registre os valores finais em `decisoes.md` (A2) e no Registro de execução.

## Verifique seu entendimento

1. Com a proposta × 0,5, refaça a previsão do M6 (app2, throughput 200, entrada no fog1). O placement fica todo nos fogs?
2. Que experimento do artigo seria mais distorcido pelo *overcommit* de CPU: o da Fig. 11 (latência dos stores) ou o da Fig. 13 (tempo de placement)? Por quê?

## Registro de execução

- Data:
- `system-reserved` finais por nó:
- Marcos refeitos e resultado:
- Diferenças em relação à Fase A:
