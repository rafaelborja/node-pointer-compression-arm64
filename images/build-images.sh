#!/bin/sh
# Monta as imagens dos add-ons Node do Home Assistant sobre UMA camada comum com o Node pointer compression.
#
# Por que: cada add-on (Zigbee2MQTT, Z-Wave JS UI) traz o seu proprio /usr/bin/node. Mesmo sendo o mesmo arquivo,
# em camadas diferentes ele vira inodes diferentes, e o kernel guarda uma copia de cada na memoria. Com todos os
# add-ons FROM a mesma camada-base, o overlay2 usa o mesmo diretorio de camada -> mesmo inode -> uma copia so.
#
#   base: FROM scratch + /opt/node-pc/bin/node (build deste repo) + /usr/bin/node (wrapper com as flags abaixo)
#   app:  estagio "strip" = imagem oficial sem /usr/bin/node; final = FROM base + COPY --from=strip / /
#         + ENV/LABEL/WORKDIR/ENTRYPOINT/CMD copiados da imagem oficial. O app e identico ao oficial; so o node muda.
#
# Uso: build-images.sh <dir com node/bin/node> <tag da base> <imagem-oficial=nome-local> ...
set -eu
NODE_DIR=$1; BASE=$2; shift 2
W=$(mktemp -d)
mkdir -p "$W/base"
cp "$NODE_DIR/bin/node" "$W/base/node"
cat > "$W/base/node-wrapper" <<'EOF'
#!/bin/sh
# Node com V8 pointer compression (github.com/rafaelborja/node-pointer-compression-arm64).
#   --max-opt=1              so o tier Sparkplug (sem Maglev/TurboFan): menos RAM de codigo otimizado.
#   --max-old-space-size=64  heap limitado; 64 e o piso medido (48 e 32 nao sobem o Zigbee2MQTT).
#   --max-semi-space-size=2  geracao nova pequena.
# NUNCA --jitless nem --lite-mode: desligam o WebAssembly, e o fetch() do Node (undici) quebra.
exec /opt/node-pc/bin/node --max-opt=1 --max-old-space-size=64 --max-semi-space-size=2 "$@"
EOF
chmod 755 "$W/base/node" "$W/base/node-wrapper"
cat > "$W/base/Dockerfile" <<'EOF'
FROM scratch
COPY node /opt/node-pc/bin/node
COPY node-wrapper /usr/bin/node
EOF
docker build -t "$BASE" "$W/base"
b0=$(docker inspect -f '{{index .RootFS.Layers 0}}' "$BASE")
esc(){ printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\$/\\$/g'; }
for pair in "$@"; do
  src=${pair%%=*}; dst=${pair#*=}; d="$W/$(echo "$dst" | tr '/:' '__')"; mkdir -p "$d"
  docker pull "$src"
  {
    echo "FROM $src AS strip"
    echo "RUN rm -f /usr/bin/node"
    echo "FROM $BASE"
    echo "COPY --from=strip / /"
    docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$src" | while IFS= read -r l; do
      [ -n "$l" ] && echo "ENV ${l%%=*}=\"$(esc "${l#*=}")\""; done
    docker inspect -f '{{range $k,$v := .Config.Labels}}{{$k}}={{$v}}{{println}}{{end}}' "$src" | while IFS= read -r l; do
      [ -n "$l" ] && echo "LABEL \"${l%%=*}\"=\"$(esc "${l#*=}")\""; done
    echo "LABEL io.github.rafaelborja.node-pc.source=\"$src\""
    wd=$(docker inspect -f '{{.Config.WorkingDir}}' "$src"); [ -n "$wd" ] && echo "WORKDIR $wd"
    ep=$(docker inspect -f '{{json .Config.Entrypoint}}' "$src"); [ "$ep" != null ] && echo "ENTRYPOINT $ep"
    cm=$(docker inspect -f '{{json .Config.Cmd}}' "$src"); [ "$cm" != null ] && echo "CMD $cm"
  } > "$d/Dockerfile"
  cat "$d/Dockerfile"
  docker build -t "$dst" "$d"
  # conferencias: primeira camada = base; node e o PC; WebAssembly e fetch vivos
  l0=$(docker inspect -f '{{index .RootFS.Layers 0}}' "$dst"); [ "$l0" = "$b0" ] || { echo "ERRO: $dst nao comeca na camada-base"; exit 1; }
  docker run --rm --entrypoint /usr/bin/node "$dst" -e '
    const pc = process.config.variables.v8_enable_pointer_compression;
    if (pc !== 1 && pc !== true) { console.error("sem pointer compression"); process.exit(1); }
    if (typeof WebAssembly !== "object") { console.error("sem WebAssembly"); process.exit(1); }
    fetch("https://example.com").then(r => console.log(process.version, "pc=1 wasm fetch=" + r.status))
      .catch(e => { console.error("fetch falhou", e.cause?.code ?? e); process.exit(1); });'
done
rm -rf "$W"
