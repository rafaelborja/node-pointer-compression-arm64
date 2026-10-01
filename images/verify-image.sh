#!/bin/sh
# Confere uma imagem de app sobre a base: 1a camada = 1a camada da base; /usr/bin/node e o Node PC (pc=1);
# WebAssembly vivo; fetch() funciona (undici precisa de WebAssembly); sobe sem comando e se comporta como a oficial
# nos primeiros 20 s (smoke). Sai != 0 se algo falhar.
# Uso: verify-image.sh <imagem> <base>
set -eu
IMG=$1; BASE=$2; PLAT=${PLATFORM:-linux/arm64}
b0=$(docker inspect -f '{{index .RootFS.Layers 0}}' "$BASE"); l0=$(docker inspect -f '{{index .RootFS.Layers 0}}' "$IMG")
[ "$l0" = "$b0" ] || { echo "ERRO $IMG: 1a camada $l0 != base $b0"; exit 1; }
out=$(MSYS_NO_PATHCONV=1 docker run --rm --platform "$PLAT" --entrypoint /usr/bin/node "$IMG" -e '
  const pc = process.config.variables.v8_enable_pointer_compression;
  if (pc !== 1 && pc !== true) { console.log("ERRO sem pointer compression"); process.exit(1); }
  if (typeof WebAssembly !== "object") { console.log("ERRO sem WebAssembly"); process.exit(1); }
  fetch("https://example.com").then(r => console.log(process.version, "pc=" + pc, "WebAssembly=" + typeof WebAssembly,
      "fetch=" + r.status, "heap_limit_MB=" + Math.round(require("v8").getHeapStatistics().heap_size_limit / 1048576)))
    .catch(e => { console.log("ERRO fetch", e.cause?.code ?? e); process.exit(1); });' 2>&1) || { echo "ERRO $IMG: $out"; exit 1; }
# Smoke: a imagem tem de subir SEM comando (como o Supervisor: docker create sem cmd) e se comportar como a oficial nos
# primeiros 20 s. Fora do Supervisor, Z2M e Matter oficiais saem (exit 1: sem config/API do Supervisor) e a zwave-js-ui
# fica de pe (s6 /init). Regra: create sem comando SEMPRE tem de funcionar; o estado apos 20 s (de pe, ou saiu com
# codigo X) tem de ser o mesmo da oficial. (2026-09-24: zwjsui-pc3 sem ENTRYPOINT -> "no command specified" no
# Supervisor, Z-Wave fora do ar 19:37-19:45; esta checagem teria pego.)
SMOKE_S=${SMOKE_S:-20}
W_ERR=$(mktemp)
smoke(){ n="smoke-$$-$2"
  MSYS_NO_PATHCONV=1 docker create --platform "$PLAT" --memory 512m --name "$n" "$1" >/dev/null 2>"$W_ERR" \
    || { echo "create-falhou: $(cat "$W_ERR")"; return 0; }
  docker start "$n" >/dev/null 2>>"$W_ERR" || true; sleep "$SMOKE_S"
  docker inspect -f 'running={{.State.Running}} exit={{.State.ExitCode}}' "$n"; docker rm -f "$n" >/dev/null 2>&1 || true; }
s_new=$(smoke "$IMG" nova)
case "$s_new" in create-falhou*) echo "ERRO $IMG: docker create sem comando falhou: $s_new"; rm -f "$W_ERR"; exit 1;; esac
SRC=$(docker inspect -f '{{index .Config.Labels "io.github.rafaelborja.node-pc.source"}}' "$IMG")
s_off=n/d
if [ -n "$SRC" ]; then
  s_off=$(smoke "$SRC" oficial)
  [ "$s_new" = "$s_off" ] || { echo "ERRO $IMG: smoke ${SMOKE_S}s difere da oficial: nova[$s_new] oficial[$s_off]"; rm -f "$W_ERR"; exit 1; }
fi
rm -f "$W_ERR"
echo "ok $IMG: $out | 1a camada = base ($b0) | smoke ${SMOKE_S}s sem comando: $s_new (oficial: $s_off)"
