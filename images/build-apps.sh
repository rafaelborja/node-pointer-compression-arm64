#!/bin/sh
# Imagens dos add-ons Node sobre a base v2 (build-base-v2.sh). O app e IDENTICO ao oficial; so o node muda.
#   estagio strip = imagem oficial sem /usr/bin/node e /usr/local/bin/node
#   final         = FROM base + COPY --from=strip / / + a config de runtime da oficial copiada EXPLICITAMENTE
#                   (ENV LABEL USER WORKDIR EXPOSE VOLUME STOPSIGNAL SHELL HEALTHCHECK ENTRYPOINT CMD; image-config.js)
# Todos comecam na MESMA camada-base -> o overlay2 usa o mesmo diretorio -> o binario do node e as libs ficam numa
# copia so no page cache, com os tres add-ons rodando.
#
# Uso: build-apps.sh <tag da base> <imagem-oficial=tag-local> ...
#   ex.: build-apps.sh local/node24pc-base:24.21.0-v2 ghcr.io/zigbee2mqtt/zigbee2mqtt-aarch64:2.14.1-1=local/z2m-pc2:2.14.1-1
set -eu
BASE=$1; shift
PLAT=${PLATFORM:-linux/arm64}
HERE=$(cd "$(dirname "$0")" && pwd)
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
# inspect SEMPRE com --platform: num indice multi-arch (zwave-js-ui) o image store do containerd devolve, sem ele, a config
# vazia de outra plataforma. Fallback sem --platform so para Docker antigo que nao conhece a opcao.
insp(){ docker image inspect --platform "$PLAT" "$1" 2>/dev/null || docker image inspect "$1"; }
for pair in "$@"; do
  src=${pair%%=*}; dst=${pair#*=}; d="$W/$(echo "$dst" | tr "/:" "__")"; mkdir -p "$d"
  docker image inspect "$src" >/dev/null 2>&1 || docker pull --platform "$PLAT" "$src"
  insp "$src" > "$d/oficial.json"
  {
    echo "FROM $src AS strip"
    echo "RUN rm -f /usr/bin/node /usr/local/bin/node"
    echo "FROM $BASE"
    echo "COPY --from=strip / /"
    node "$HERE/image-config.js" dockerfile "$d/oficial.json"      # ENV/LABEL/USER/WORKDIR/.../ENTRYPOINT/CMD
    echo "LABEL io.github.rafaelborja.node-pc.source=\"$src\""
  } > "$d/Dockerfile"
  cat "$d/Dockerfile"
  docker build --platform "$PLAT" --provenance=false -t "$dst" "$d"
  # conferencia ESTRITA da config de runtime contra a oficial (sem tolerancia em Entrypoint/Cmd)
  insp "$dst" > "$d/nova.json"
  node "$HERE/image-config.js" compare "$d/oficial.json" "$d/nova.json" || { echo "ERRO $dst: config difere da oficial"; exit 1; }
  sh "$HERE/verify-image.sh" "$dst" "$BASE"
done
