# WAN emulada entre fog e cloud

## Objetivo

Fazer o tráfego de e para o cloud1 sofrer atraso (e, opcionalmente, limite de banda) como numa WAN, enquanto o tráfego entre os fogs continua com latência de LAN.

## Conceitos

No artigo (§6.1.1), os fogs ficam num data center da Univ. de Melbourne, ligados por LAN, e o cloud1 fica na AWS (ap-southeast-2, Sydney), acessado pela internet. É essa diferença que explica as figuras:
- Fig. 11: o failover para a cloud é mais lento que o failover para outro fog.
- Fig. 12: FP2 (`to_cloud`) dá mais latência que FP1.
- Fig. 17: o V1, que empurra o placement para a cloud, tem mais latência que o V2.

No nosso switch, todos os PCs estão a ~0,2 ms uns dos outros. Sem emulação, essas diferenças **desaparecem**.

O `tc netem` (Linux) atrasa, perde ou limita os pacotes que **saem** por uma interface.

### Qual atraso? (questão em aberto A1)

| Objetivo | Sugestão |
|---|---|
| Ver funcionando (diferença bem visível) | +50 ms de RTT |
| Replicação fiel | RTT típica Melbourne → Sydney: ~10–20 ms. Meça, se puder, ou use valores publicados, e registre a fonte |

## Passos

### 1. Medir antes

```bash
fog1$ ping -c 20 192.168.0.13 | tail -1     # RTT fog1 → cloud1, sem emulação
fog1$ ping -c 20 192.168.0.12 | tail -1     # RTT fog1 → fog2 (referência)
```

### 2. Aplicar no cloud1

Aplicando o atraso **só na saída** do cabo do cloud1, o RTT de qualquer conversa com o cloud1 aumenta pelo valor configurado (as respostas saem atrasadas):

```bash
cloud1$ IF=eno1                                   # a interface do CABO, não a da Wi-Fi
cloud1$ sudo tc qdisc add dev $IF root netem delay 50ms 5ms distribution normal rate 100mbit
cloud1$ tc qdisc show dev $IF
```

- `delay 50ms 5ms distribution normal`: 50 ms em média, com variação (jitter) de 5 ms.
- `rate 100mbit`: limite de banda (opcional).

A internet do cloud1 também sai pelo cabo, então a regra atrasa os downloads dele. Faça os pulls de imagens antes de aplicá-la. Como os manifestos usam `imagePullPolicy: IfNotPresent` (M3, passo 4), as imagens do app2 já baixadas no M6 continuam no cache dos nós e não são baixadas de novo.

Para dividir o atraso entre ida e volta, aplique metade aqui e metade na **entrada** (é preciso um dispositivo `ifb`). Ou aplique também na saída dos outros PCs, com um filtro só para o destino `192.168.0.13`. Para ver funcionando, a forma simples basta.

### 3. Medir depois

```bash
fog1$ ping -c 20 192.168.0.13 | tail -1     # deve subir ~50 ms
fog1$ ping -c 20 192.168.0.12 | tail -1     # deve ficar igual
```

### 4. Refazer o M6 com a WAN

Com a regra ativa, apague o `app2`:

```bash
clusters$ kubectl delete ns app2
```

Repita os passos 2–5 do [M6](m6-placement-distribuido.md), com FP1 (`to_rand_fog`) e com FP2 (`to_cloud`). Em cada política, meça a latência do `curl` do passo 4 do M6 em 10 repetições. O `-w '%{time_total}'` imprime o tempo total da requisição, em segundos:

`carga$`:

```bash
for i in $(seq 10); do
  curl -s -o /dev/null -w '%{time_total}\n' \
    -H 'Host: a2m1.app2.svc.cluster.local' -H 'Content-Type: application/json' \
    -X GET http://192.168.0.11/DummyM/getResults -d '{"message":[65,68,67],"dataProcessingTime":30}'
done | awk '{s+=$1; print} END {printf "média: %.3f s\n", s/NR}'
```

Compare com a do M6 sem WAN, medida da mesma forma (remova a regra no passo 5, refaça e meça). Agora a diferença entre as políticas deve aparecer (Fig. 12).

### 5. Remover

```bash
cloud1$ sudo tc qdisc del dev eno1 root
cloud1$ tc qdisc show dev eno1        # volta a mostrar a fila padrão (fq_codel ou similar), sem netem
```

A regra **não sobrevive a um reboot**. Isso é bom num laboratório, porque não fica esquecida. Registre o comando usado em cada experimento.

## O que observar

- O tráfego **dentro** do cloud1 (entre os nós KinD, pela bridge Docker) **não** é afetado, só o que sai pelo cabo. Por quê?

## Verifique seu entendimento

1. O tráfego do PC `carga` para o cloud1 também fica atrasado. Isso é desejável? Que cenário real ele representa?
2. Que parte da malha Istio é afetada pela WAN além das chamadas entre microserviços? (Pense no `istiod` lendo os API servers remotos e na replicação do MinIO/Redis.)

## Registro de execução

- Data:
- Comando `tc` usado:
- RTT antes e depois (fog1 → cloud1, fog1 → fog2):
- Latência do `curl` do M6 com a WAN, FP1 × FP2 (10 repetições):
