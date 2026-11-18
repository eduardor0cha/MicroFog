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

Faça o build no PC `carga`, que não roda cluster e não disputa CPU com eles. Para não depender da versão de JDK do Ubuntu 26.04 (o projeto compila para Java 11, e a imagem roda em OpenJDK 17), o Maven roda **dentro de um container**.

Os autores publicaram só as imagens prontas, no Docker Hub. Compilar as nossas a partir deste código garante que o que roda nos clusters é o código que estamos lendo, e as imagens dos autores ficam como alternativa (D15).

### 1. Organização e token do GHCR

As imagens ficam no GHCR, o registry do GitHub, que não tem o limite de pulls do Docker Hub, e numa **organização** do grupo, não numa conta pessoal (D16). Assim, o endereço das imagens não depende de ninguém, e cada membro publica com o próprio token.

**Uma vez só, por quem administra o grupo**, no GitHub:

1. *+ → New organization → Free*. Use um nome **só com minúsculas**: o nome entra no endereço das imagens, e o Docker recusa maiúsculas.
2. Na organização, *Settings → Packages → Package creation*: marque **Public**. Sem isso, os pacotes não podem ficar públicos (passo 4).
3. *People → Invite member*: convide quem vai rodar o M0.

**Cada pessoa que for publicar**, na própria conta: *Settings → Developer settings → Personal access tokens (classic)*, com o escopo `write:packages` e uma data de expiração. Copie o token gerado. Se a organização usar SSO, autorize o token nela (*Configure SSO*).

`carga$` (pc-lamp-5) grave o nome da organização no `~/.bashrc`. Os comandos deste marco usam `$GHCR_ORG`, que assim continua definida em qualquer shell novo:

```bash
echo 'export GHCR_ORG=nome-da-org' >> ~/.bashrc     # troque nome-da-org
source ~/.bashrc
echo "$GHCR_ORG"
```

`carga$` (pc-lamp-5) faça login com o **seu** usuário do GitHub. O `read -s` lê o token sem mostrá-lo na tela nem gravá-lo no histórico do shell. Digite o usuário, tecle `Enter`, cole o token e tecle `Enter`:

```bash
read -p "Usuário do GitHub: " GH_USER
read -s -p "Token: " CR_PAT; echo
echo "$CR_PAT" | docker login ghcr.io -u "$GH_USER" --password-stdin    # "Login Succeeded"
unset CR_PAT
```

O `docker login` grava o token em `~/.docker/config.json`, em base64, que não é criptografia. Enquanto ele estiver lá, quem usar esse usuário do `carga` publica em seu nome. Por isso, o passo 4 faz `docker logout` logo depois do push.

### 2. Build do CE

`carga$` (pc-lamp-5) compile o CE, gere a imagem e publique-a:

```bash
cd ~/MicroFog/ControlEngine
docker run --rm -v "$PWD":/src -v "$HOME/.m2":/root/.m2 -w /src \
  maven:3.9-eclipse-temurin-17 mvn -B package -DskipTests
TAG=src-$(git rev-parse --short HEAD)
docker build -f src/main/docker/Dockerfile.jvm -t ghcr.io/$GHCR_ORG/microfog:$TAG .
docker push ghcr.io/$GHCR_ORG/microfog:$TAG
```

`-DskipTests` é necessário porque os testes em `src/test` precisam de um cluster e de Redis/MinIO rodando.

### 3. Build dos microserviços de teste

Para cada microserviço, o script abaixo troca o namespace e o ConfigMap no `application.properties`, compila e publica.

`carga$` (pc-lamp-5) antes, **confira** os nomes dos ConfigMaps. O script supõe que cada um se chama `<microserviço>-config`:

```bash
cd ~/MicroFog/Workload_Generator/dummy-micro-java
grep -h "name:" ../sample-deployment-resources/*/*-config.yaml
```

`carga$` (pc-lamp-5) grave o script:

```bash
cat > ~/build-dummies.sh <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
: "${GHCR_ORG:?defina GHCR_ORG (M0, passo 1)}"
cd ~/MicroFog/Workload_Generator/dummy-micro-java
PROPS=src/main/resources/application.properties
cp $PROPS /tmp/application.properties.orig
# Restaura o arquivo original mesmo se um build falhar no meio do laço
trap 'cp /tmp/application.properties.orig $PROPS' EXIT

# microserviço:namespace
for pair in hcm1:hcapp hcm2:hcapp hcm3:hcapp a2m1:app2 a2m2:app2 a2m3:app2 a2m4:app2; do
  ms=${pair%%:*}; ns=${pair##*:}
  sed -i -E "s/^(quarkus.kubernetes-client.namespace=).*/\1$ns/; \
             s/^(quarkus.kubernetes-config.config-maps=).*/\1$ms-config/" $PROPS
  docker run --rm -v "$PWD":/src -v "$HOME/.m2":/root/.m2 -w /src \
    maven:3.9-eclipse-temurin-17 mvn -B -q package -DskipTests
  docker build -f src/main/docker/Dockerfile.jvm -t ghcr.io/$GHCR_ORG/dummy-microservice:$ms .
  docker push ghcr.io/$GHCR_ORG/dummy-microservice:$ms
done
SCRIPT
```

`carga$` (pc-lamp-5) rode o script e confira que o `application.properties` voltou ao original:

```bash
bash ~/build-dummies.sh
cd ~/MicroFog && git status --short     # não deve listar o application.properties
```

Quando o script funcionar, guarde uma cópia em `reproducao/scripts/build-dummies.sh`, neste repositório.

### 4. Tornar os pacotes públicos

O primeiro push cria cada pacote na organização como **privado**. No GitHub, na página da organização: *Packages → microfog → Package settings → Change visibility → Public*. Repita para `dummy-microservice`. Sem isso, os nós KinD precisariam de `imagePullSecrets`. A opção só aparece se a organização permitir pacotes públicos (passo 1).

Na mesma página, em *Manage access*, dê o papel **Write** aos membros (ou a um time) que também vão publicar. Por padrão, só quem fez o primeiro push e os donos da organização podem publicar novas versões.

`carga$` (pc-lamp-5) confira sem login. O `docker logout` simula um nó do KinD, que não tem credenciais:

```bash
docker logout ghcr.io
docker pull ghcr.io/$GHCR_ORG/dummy-microservice:hcm1    # deve baixar sem "denied"
```

### 5. Registrar os digests

O digest identifica o conteúdo da imagem. Os manifestos usam o digest, e não a tag, para que uma republicação da tag não troque a imagem no meio dos experimentos (D15).

`carga$` (pc-lamp-5) liste os digests. O `TAG` do passo 2 se perde quando você abre outro shell, por isso o primeiro comando o recria:

```bash
cd ~/MicroFog/ControlEngine && TAG=src-$(git rev-parse --short HEAD)
docker inspect --format '{{index .RepoDigests 0}}' ghcr.io/$GHCR_ORG/microfog:$TAG
for ms in hcm1 hcm2 hcm3 a2m1 a2m2 a2m3 a2m4; do
  echo "$ms $(docker inspect --format '{{index .RepoDigests 0}}' ghcr.io/$GHCR_ORG/dummy-microservice:$ms)"
done
```

Cada linha impressa é a referência completa, já com a organização e o digest (`ghcr.io/<org>/microfog@sha256:...`). Anote-as na tabela abaixo: o M3 usa essas linhas como estão.

## Origem das imagens (`IMAGE_SOURCE`)

Os manifestos do repositório usam `samodha/...:latest` com `imagePullPolicy: Always`. Vamos trocar ambos: a imagem passa a ser escolhida por `IMAGE_SOURCE` e é sempre fixada por **digest**, com `imagePullPolicy: IfNotPresent`.

| Imagem | `upstream` (autores, Docker Hub, digests de 2026-11-02) | `local` (nossa, GHCR) |
|---|---|---|
| CE | `samodha/microfog@sha256:b6342ae19edfd854d3102564cc6e7da65369c45cebbf459f900811607adb93c2` | `ghcr.io/<org>/microfog@sha256:…` |
| hcm1 | `samodha/dummy-microservice-test@sha256:ab602dab1e525d2df7d4a1e2a13bd65abc35082f50edd938e419edb1d2977a36` | `ghcr.io/<org>/dummy-microservice@sha256:…` |
| hcm2 | `samodha/dummy-microservice-test@sha256:d81db14c03cae3ffbf3c01dfbd75f7d3cf5dca9c4cb99c6022adf41dddd8389b` | … |
| hcm3 | `samodha/dummy-microservice-test@sha256:071e1c1d50a62bf2d2b1e5b0ae2eec8dd6ae62513765ac38c80ac56c47904a6e` | … |
| a2m1 | `samodha/dummy-microservice-test@sha256:b7f74d3dfe4901adf1617875da29e9862bfcfa26b6ced43dc2e8c7a42014497a` | … |
| a2m2 | `samodha/dummy-microservice-test@sha256:fac0e64e3c067341d764153fbe797de2892ff6c3742cc778489e733b90730ecf` | … |
| a2m3 | `samodha/dummy-microservice-test@sha256:0a7c1c205828cb1c6151a9ea118c76ba7f3b96250966e131e05827c4954e8af5` | … |
| a2m4 | `samodha/dummy-microservice-test@sha256:d96418b90992cf69c1c2ebb037543ea3c7e42a06557f2e9574d8fbad2850f47a` | … |

A tag `samodha/microfog:latest` foi publicada em 2023-02-10, um dia depois do último commit do código do CE (2023-02-09). É provável, mas não garantido, que corresponda a este código.

O script `~/set-images.sh`, escrito no [M3, passo 4](m3-data-stores.md#4-upload-dos-yamls-das-aplicações), reescreve os campos `image:` em:
- `Prototype_Setup/control-engine-setup/controller-*.yaml` (CE);
- os YAMLs das aplicações antes do upload para o MinIO (M3).

## O que observar

- O `mvn package` termina com `BUILD SUCCESS` e gera `target/quarkus-app/`.
- As imagens aparecem em `https://github.com/orgs/<org>/packages`.

Se o build falhar por causa de dependências de 2022, **não pare o plano**: siga com `IMAGE_SOURCE=upstream` e volte ao build depois (decisão D15).

## Verifique seu entendimento

1. Abra os metadados do hcApp (`less ~/MicroFog/ControlEngine/src/main/java/com/microfog/controlengine/metadata/SmartHealthAppSetup.java`). Quantos microserviços e quantos serviços compostos tem o hcApp? Compare com a Fig. 2 do artigo.
2. Qual o requisito de CPU e de *throughput* de cada microserviço do hcApp? Se um PR pedir 200 req/s, quantas instâncias de hcm2 o V2 vai colocar? *(Dica: `placementlogic/DistributedPlacement.java`, método `getInstancesToPlace`.)*
3. Por que a imagem do dummy precisa saber o próprio namespace?

## Problemas comuns

| Sintoma | Causa provável | Diagnóstico |
|---|---|---|
| `Could not resolve dependencies` | Artefato de 2022 removido de um repositório Maven | Veja qual artefato e procure a versão mais próxima. Registre a mudança |
| `denied: permission_denied` no push | Token sem `write:packages` | Gere outro token |
| `denied` no push com o token certo | Você não é membro da organização, ou não tem **Write** no pacote | Passo 1 (convite) e passo 4 (*Manage access*) |
| `denied` só no fim do primeiro push de um pacote novo, depois de todas as camadas `Pushed`, e o pacote aparece criado na organização | O GHCR às vezes recusa a primeira escrita logo depois de criar o pacote | Repita o `docker push` da mesma tag. Se foi no `build-dummies.sh`, rode o script de novo |
| `invalid reference format` no build | `GHCR_ORG` vazia, ou com maiúsculas | `echo "$GHCR_ORG"`; passo 1 |
| Pod depois em `ErrImagePull` | Pacote ainda privado no GHCR | Passo 4 |

## Registro de execução

- Data:
- Commit do repositório (`git rev-parse HEAD`):
- Build do CE: sucesso / falhou (motivo):
- Organização (`GHCR_ORG`):
- Digests gerados:
- Desvios do plano:
