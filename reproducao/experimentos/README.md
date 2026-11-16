# Experimentos E1–E5 (esboço)

Roteiro para a **replicação fiel** da Seção 6.2, depois das lições. Ainda não é um procedimento: faltam as decisões em aberto A1 (perfil da WAN), A2 (tamanhos dos nós) e A3 (repetições e estatística) de [`decisoes.md`](../decisoes.md).

Critério de sucesso sugerido: reproduzir a **ordem e o sentido** dos efeitos (qual cenário é mais rápido, quanto cresce). Os números absolutos dependem do hardware e da rede do artigo, que não temos.

| # | Figura | Pergunta | Cenários | O que medir | Onde está o dado | Pré-requisito |
|---|---|---|---|---|---|---|
| E1 | Fig. 11 | O failover dos stores prioriza fog antes de cloud? | 1: todos os stores; 2: sem fog1; 3: sem fog1 e fog2 | Latência relativa de leitura do MinIO e do Redis | `LOAD_YAML_FILE_BEGIN/COMPLETED`, `RETRIEVE_REDIS_DATA_BEGIN/END` no CE do fog1 | [M9](../licoes/m9-failover.md), WAN |
| E2 | Fig. 12 | Como a política de forwarding afeta a aplicação? | 1: cabe no fog de entrada; 2: FP1 (`to_rand_fog`); 3: FP2 (`to_cloud`) | Tempo de resposta da aplicação | Cliente (`hey`/JMeter no PC `carga`) | M6, WAN |
| E3 | Fig. 13 | Distribuído escala melhor que centralizado? | 5 PRs (3 no fog1 + 2 no fog2); 10 PRs (5 + 5); 15 PRs (5 + 5 + 5, com fog3). Distribuído com V2 × centralizado com V3 | Tempo total até o deploy de todos os PRs, em modo event-driven | `NEW_PR_RECEIVED` (primeiro) → último `PLACEMENT_COMPLETED`/pods `Running` | M6, M8, fog3, script de PRs simultâneos |
| E4 | Fig. 14 | k3s implanta mais rápido que k8s? | 1: PR no fog1 (k8s); 2: PR no fog3 (k3s); 3: placement entre os dois | Tempo até o deploy | Eventos do CE + pods `Running` | [fog3-k3d](../licoes/fog3-k3d.md) |
| E5 | Tabela 3, Fig. 15–17 | V2 melhora a latência em relação ao V1? O WRR segue os recursos? | app2 e hcApp, com V1 e com V2 | Latência da aplicação (o artigo: −44% app2, −54% hcApp); distribuição de tráfego por instância | Cliente; Kiali; contagem nos logs ([M7](../licoes/m7-wrr.md)) | M6, M7, WAN |

## Decisões a tomar antes de executar

- **Repetições e estatística** (A3): quantas execuções por cenário, como descartar *warm-up* (a primeira requisição depois de um deploy costuma ser lenta por causa do JIT da JVM e da configuração do Envoy), mediana × média, intervalos de confiança.
- **Isolamento**: limpar namespaces e reiniciar CEs entre execuções? Garantir que o Redis não tem estado residual?
- **Carga**: o artigo não detalha a carga do E2/E5. Defina taxa, duração e tamanho das mensagens e registre.
- **Tamanhos**: escalar os requisitos das aplicações junto com os nós (A2), para que o placement da Tabela 3 seja reproduzível?
- **Ferramentas de coleta**: um script que extraia os eventos dos logs (Loki ou `kubectl logs`) e calcule os intervalos, guardado em `reproducao/scripts/`.
