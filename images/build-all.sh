#!/bin/sh
# Tudo de uma vez, num host com Docker (amd64 com emulacao arm64, ou runner arm64):
#   1. node do release (sha256 conferido)        4. pc3 = fonte limpa (clean-source.sh) sobre cada pc2
#   2. base v2 (build-base-v2.sh)                5. conferencia de cada imagem (verify-image.sh)
#   3. pc2 = apps oficiais sobre a base          6. docker save base + tres pc3 -> um .tar.gz (camada comum 1x)
#
# Uso: build-all.sh <dir de saida>     (Git Bash no Windows funciona)
# Env: NODE_RELEASE (v24.21.0-pc-musl)  TAGNS (local -> local/node24pc-base:24.21.0-v2, local/z2m-pc3:2.14.1-1 ...)
#      CLEAN_LIST (ALL = todos os .js/.mjs/.cjs, padrao; ou um diretorio com <app>.txt, uma lista por app)
#      Z2M ZWJSUI MATTER (imagens oficiais)  CLEAN_EXCLUDE_<app> (regex de exclusao, ver clean-source.sh)
#      ONLY_PC3=1: pula node/base/pc2 (ja construidas) e refaz so pc3 + conferencia + save
set -eu
# Git Bash: MSYS_NO_PATHCONV=1 so nos `docker run` (caminhos DENTRO do conteiner); `docker build <dir>` precisa da conversao.
OUT=$1; mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
NR=${NODE_RELEASE:-v24.21.0-pc-musl}; NS=${TAGNS:-local}; CL=${CLEAN_LIST:-ALL}
lst(){ if [ "$CL" = ALL ]; then echo ALL; else echo "$CL/$1.txt"; fi; }
Z2M=${Z2M:-ghcr.io/zigbee2mqtt/zigbee2mqtt-aarch64:2.14.1-1}
ZWJSUI=${ZWJSUI:-ghcr.io/hassio-addons/zwave-js-ui:7.7.0}
MATTER=${MATTER:-homeassistant/aarch64-addon-matter-server:9.2.0}
NV=${NR%%-*}; NV=${NV#v}
BASE=$NS/node24pc-base:$NV-v2
log(){ echo "== $(date +%T) $*"; }

if [ "${ONLY_PC3:-}" != 1 ]; then
log "node $NR"
mkdir -p "$OUT/dl"
if ! ls "$OUT"/dl/*.tar.xz >/dev/null 2>&1; then
  (cd "$OUT/dl" && gh release download "$NR" --repo rafaelborja/node-pointer-compression-arm64 \
     --pattern '*.tar.xz' --pattern '*.tar.xz.sha256')
fi
(cd "$OUT/dl" && sha256sum -c ./*.sha256)
TARBALL=$(ls "$OUT"/dl/*.tar.xz | head -1)

log "base $BASE"; sh "$HERE/build-base-v2.sh" "$TARBALL" "$BASE"

log "pc2"
sh "$HERE/build-apps.sh" "$BASE" "$Z2M=$NS/z2m-pc2:${Z2M##*:}" "$ZWJSUI=$NS/zwjsui-pc2:${ZWJSUI##*:}" \
  "$MATTER=$NS/matter-pc2:${MATTER##*:}"
fi

log "pc3 (fonte limpa)"
CLEAN_EXCLUDE=${CLEAN_EXCLUDE_z2m:-} sh "$HERE/clean-source.sh" "$NS/z2m-pc2:${Z2M##*:}" "$(lst z2m)" \
  "$NS/z2m-pc3:${Z2M##*:}" /app
CLEAN_EXCLUDE=${CLEAN_EXCLUDE_zwjsui:-} sh "$HERE/clean-source.sh" "$NS/zwjsui-pc2:${ZWJSUI##*:}" "$(lst zwjsui)" \
  "$NS/zwjsui-pc3:${ZWJSUI##*:}" /opt
CLEAN_EXCLUDE=${CLEAN_EXCLUDE_matter:-} sh "$HERE/clean-source.sh" "$NS/matter-pc2:${MATTER##*:}" "$(lst matter)" \
  "$NS/matter-pc3:${MATTER##*:}" /app /usr/local/lib/node_modules

log "conferencia"
IMGS="$NS/z2m-pc3:${Z2M##*:} $NS/zwjsui-pc3:${ZWJSUI##*:} $NS/matter-pc3:${MATTER##*:}"
for i in $IMGS; do
  # config de runtime do pc3 = da oficial, ESTRITO (a pc3 herda da pc2; confere de novo porque e ela que vai para o VM)
  src=$(docker inspect -f '{{index .Config.Labels "io.github.rafaelborja.node-pc.source"}}' "$i")
  docker image inspect --platform linux/arm64 "$src" > "$OUT/oficial.json" 2>/dev/null || docker image inspect "$src" > "$OUT/oficial.json"
  docker image inspect --platform linux/arm64 "$i" > "$OUT/nova.json" 2>/dev/null || docker image inspect "$i" > "$OUT/nova.json"
  node "$HERE/image-config.js" compare "$OUT/oficial.json" "$OUT/nova.json" || { echo "ERRO $i: config difere de $src"; exit 1; }
  sh "$HERE/verify-image.sh" "$i" "$BASE"
done
rm -f "$OUT/oficial.json" "$OUT/nova.json"
# o Matter Server importa com o node novo e o codigo limpo? (so o modulo principal; sobe a CLI e sai com --help)
MSYS_NO_PATHCONV=1 docker run --rm --platform linux/arm64 -e LOG_LEVEL=info --entrypoint /bin/sh "$NS/matter-pc3:${MATTER##*:}" -c \
  'cd /app && timeout 120 node node_modules/matter-server/dist/esm/MatterServer.js --help 2>&1 | head -3'

log "docker save"
# shellcheck disable=SC2086
docker save "$BASE" $IMGS | gzip -6 > "$OUT/node-addon-images-pc3.tar.gz"
(cd "$OUT" && sha256sum node-addon-images-pc3.tar.gz > node-addon-images-pc3.tar.gz.sha256)
{ echo "base: $BASE  1a camada: $(docker inspect -f '{{index .RootFS.Layers 0}}' "$BASE")  id: $(docker inspect -f '{{.Id}}' "$BASE")"
  for i in $IMGS; do echo "$i  1a camada: $(docker inspect -f '{{index .RootFS.Layers 0}}' "$i")  id: $(docker inspect -f '{{.Id}}' "$i")"; done
  echo
  echo "fonte limpa: esbuild sem --keep-names, exceto nos arquivos em que ele mudaria um nome (decisao por arquivo):"
  for i in $IMGS; do
    a=${i##*/}; a=${a%%-pc3*}
    MSYS_NO_PATHCONV=1 docker run --rm --platform linux/arm64 --entrypoint cat "$i" /opt/node-pc/clean-resumo-$a.txt | sed "s/^/  $a: /"
    MSYS_NO_PATHCONV=1 docker run --rm --platform linux/arm64 --entrypoint cat "$i" /opt/node-pc/clean-keepnames-$a.txt > "$OUT/keepnames-$a.txt"
    echo "  $a: $(wc -l < "$OUT/keepnames-$a.txt") arquivos com --keep-names:"; sed 's/^/    /' "$OUT/keepnames-$a.txt"
  done
} > "$OUT/MANIFEST.txt"
cat "$OUT/MANIFEST.txt"; ls -la "$OUT/node-addon-images-pc3.tar.gz"
