# M0 — Build das imagens

## Objetivo

Compilar, a partir do código deste repositório, a imagem do **MicroFog-CE** e as 7 imagens dos microserviços de teste (hcApp: hcm1–hcm3; app2: a2m1–a2m4), e publicá-las no GHCR. No fim, a variável `IMAGE_SOURCE` permite escolher entre as nossas imagens e as dos autores.

## Conceitos

### O que é o Control Engine (§3.3.1)

O **MicroFog-CE** é o "cérebro" do framework: um microserviço Java (Quarkus) instalado **em cada cluster**. Ele recebe *Placement Requests* (PRs), executa o algoritmo de placement e cria os recursos Kubernetes e Istio que implantam a aplicação. Fica em `ControlEngine/`:

| Pacote | Papel no artigo |
|---|---|
| `services/` | As 3 APIs REST (Fig. 8–10): `addPR`, `getClusterData`, `submitDeploymentInfo` |
| `placementlogic/` | Algoritmos de placement: `DistributedPlacement` (V1/V2/V3, §6.1.3) |
| `requestForwardingLogic/` | Políticas de forwarding de PR (FP1/FP2, §6.2.1) |
| `loadBalancing/` | Política de load balancing (Weighted Round Robin, §6.2.2) |
| `controllers/` | Leitura de recursos dos nós, deploy de YAMLs, filas, modo periódico |
| `metadata/` | **Descrição das aplicações** (microserviços, dataflows, serviços compostos), fixa em Java |

O último item é importante: os metadados das aplicações (por exemplo, "hcm2 precisa de 1 CPU e suporta 100 req/s") estão em `metadata/SmartHealthAppSetup.java` e `DummyApp2Setup.java`. Mudar uma aplicação exige **recompilar o CE**.

### O gerador de workload (§6.1.2)

`Workload_Generator/dummy-micro-java` é um microserviço "genérico". O comportamento dele (quem ele chama, quanto tempo "processa", tamanho das mensagens) vem de um **ConfigMap** lido em tempo de execução: veja `sample-deployment-resources/hcApp/hcm1-config.yaml`. Mas o `application.properties` **embutido na imagem** fixa *qual* ConfigMap ler e em que namespace:

```properties
quarkus.kubernetes-client.namespace=hcapp
quarkus.kubernetes-config.config-maps=hcm1-config
```

Por isso os autores publicaram uma imagem por microserviço (`samodha/dummy-microservice-test:hcm1`, `:hcm2`...). O código é o mesmo e muda só esse arquivo.

## Passos

Faça o build numa das VMs (`fog1`). Para não depender da versão de JDK do Ubuntu 26.04 (o projeto compila para Java 11, e a imagem roda em OpenJDK 17), o Maven roda **dentro de um container**.

### 1. Token do GHCR

No GitHub: *Settings → Developer settings → Personal access tokens (classic)*, com o escopo `write:packages`.

```bash
fog1$ echo "$CR_PAT" | docker login ghcr.io -u eduardor0cha --password-stdin
```

### 2. Build do CE

```bash
fog1$ cd ~/MicroFog/ControlEngine
fog1$ docker run --rm -v "$PWD":/src -v "$HOME/.m2":/root/.m2 -w /src \
        maven:3.9-eclipse-temurin-17 mvn -B package -DskipTests
fog1$ TAG=src-$(git rev-parse --short HEAD)
fog1$ docker build -f src/main/docker/Dockerfile.jvm -t ghcr.io/eduardor0cha/microfog:$TAG .
fog1$ docker push ghcr.io/eduardor0cha/microfog:$TAG
```

`-DskipTests` é necessário porque os testes em `src/test` precisam de um cluster e de Redis/MinIO rodando.

### 3. Build dos microserviços de teste

Para cada microserviço, troque o namespace e o ConfigMap no `application.properties`, compile e publique. Esboço do script (salve como `reproducao/scripts/build-dummies.sh` quando tiver testado):

```bash
cd ~/MicroFog/Workload_Generator/dummy-micro-java
PROPS=src/main/resources/application.properties
cp $PROPS /tmp/application.properties.orig

# microserviço:namespace
for pair in hcm1:hcapp hcm2:hcapp hcm3:hcapp a2m1:app2 a2m2:app2 a2m3:app2 a2m4:app2; do
  ms=${pair%%:*}; ns=${pair##*:}
  sed -i -E "s/^(quarkus.kubernetes-client.namespace=).*/\1$ns/; \
             s/^(quarkus.kubernetes-config.config-maps=).*/\1$ms-config/" $PROPS
  docker run --rm -v "$PWD":/src -v "$HOME/.m2":/root/.m2 -w /src \
    maven:3.9-eclipse-temurin-17 mvn -B -q package -DskipTests
  docker build -f src/main/docker/Dockerfile.jvm -t ghcr.io/eduardor0cha/dummy-microservice:$ms .
  docker push ghcr.io/eduardor0cha/dummy-microservice:$ms
done
cp /tmp/application.properties.orig $PROPS
```

Antes do laço, **confira** os nomes dos ConfigMaps (`grep -h "name:" ../sample-deployment-resources/*/*-config.yaml`).

### 4. Tornar os pacotes públicos

No GitHub: *Your profile → Packages → microfog → Package settings → Change visibility → Public*. Repita para `dummy-microservice`. Sem isso, os nós KinD precisariam de `imagePullSecrets`.

### 5. Registrar os digests

```bash
fog1$ docker inspect --format '{{index .RepoDigests 0}}' ghcr.io/eduardor0cha/microfog:$TAG
```

Anote os digests na tabela abaixo.

## Origem das imagens (`IMAGE_SOURCE`)

Os manifestos do repositório usam `samodha/...:latest` com `imagePullPolicy: Always`. Vamos trocar ambos: a imagem passa a ser escolhida por `IMAGE_SOURCE` e é sempre fixada por **digest**, com `imagePullPolicy: IfNotPresent`.

| Imagem | `upstream` (autores, Docker Hub, digests de 2026-11-02) | `local` (nossa, GHCR) |
|---|---|---|
| CE | `samodha/microfog@sha256:b6342ae19edfd854d3102564cc6e7da65369c45cebbf459f900811607adb93c2` | `ghcr.io/eduardor0cha/microfog@sha256:…` |
| hcm1 | `samodha/dummy-microservice-test@sha256:ab602dab1e525d2df7d4a1e2a13bd65abc35082f50edd938e419edb1d2977a36` | `ghcr.io/eduardor0cha/dummy-microservice@sha256:…` |
| hcm2 | `samodha/dummy-microservice-test@sha256:d81db14c03cae3ffbf3c01dfbd75f7d3cf5dca9c4cb99c6022adf41dddd8389b` | … |
| hcm3 | `samodha/dummy-microservice-test@sha256:071e1c1d50a62bf2d2b1e5b0ae2eec8dd6ae62513765ac38c80ac56c47904a6e` | … |
| a2m1 | `samodha/dummy-microservice-test@sha256:b7f74d3dfe4901adf1617875da29e9862bfcfa26b6ced43dc2e8c7a42014497a` | … |
| a2m2 | `samodha/dummy-microservice-test@sha256:fac0e64e3c067341d764153fbe797de2892ff6c3742cc778489e733b90730ecf` | … |
| a2m3 | `samodha/dummy-microservice-test@sha256:0a7c1c205828cb1c6151a9ea118c76ba7f3b96250966e131e05827c4954e8af5` | … |
| a2m4 | `samodha/dummy-microservice-test@sha256:d96418b90992cf69c1c2ebb037543ea3c7e42a06557f2e9574d8fbad2850f47a` | … |

A tag `samodha/microfog:latest` foi publicada em 2023-02-10, um dia depois do último commit do código do CE (2023-02-09). É provável, mas não garantido, que corresponda a este código.

Um script `reproducao/scripts/set-images.sh` (a escrever no M3, quando os YAMLs forem enviados ao MinIO) vai reescrever os campos `image:` em:
- `Prototype_Setup/control-engine-setup/controller-*.yaml` (CE);
- os YAMLs das aplicações antes do upload para o MinIO (M3).

## O que observar

- O `mvn package` termina com `BUILD SUCCESS` e gera `target/quarkus-app/`.
- As imagens aparecem em `https://github.com/eduardor0cha?tab=packages`.

Se o build falhar por causa de dependências de 2022, **não pare a Fase A**: siga com `IMAGE_SOURCE=upstream` e volte ao build depois (decisão D15).

## Verifique seu entendimento

1. Abra `metadata/SmartHealthAppSetup.java`. Quantos microserviços e quantos serviços compostos tem o hcApp? Compare com a Fig. 2 do artigo.
2. Qual o requisito de CPU e de *throughput* de cada microserviço do hcApp? Se um PR pedir 200 req/s, quantas instâncias de hcm2 o V2 vai colocar? *(Dica: `placementlogic/DistributedPlacement.java`, método `getInstancesToPlace`.)*
3. Por que a imagem do dummy precisa saber o próprio namespace?

## Problemas comuns

| Sintoma | Causa provável | Diagnóstico |
|---|---|---|
| `Could not resolve dependencies` | Artefato de 2022 removido de um repositório Maven | Veja qual artefato e procure a versão mais próxima. Registre a mudança |
| `denied: permission_denied` no push | Token sem `write:packages` | Gere outro token |
| Pod depois em `ErrImagePull` | Pacote ainda privado no GHCR | Passo 4 |

## Registro de execução

- Data:
- Commit do repositório (`git rev-parse HEAD`):
- Build do CE: sucesso / falhou (motivo):
- Digests gerados:
- Desvios do plano:
