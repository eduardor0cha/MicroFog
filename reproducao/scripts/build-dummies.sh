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
