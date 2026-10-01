#!/bin/sh
# Imagem-base v2 (linux/arm64): o Node pointer compression (musl) AUTOCONTIDO em /opt/node-pc -- leva o proprio loader
# musl e libstdc++/libgcc_s em /opt/node-pc/lib (patchelf: interpretador + rpath), entao roda sobre Alpine (Z2M,
# Z-Wave JS UI) e sobre Debian/glibc (Matter Server). /usr/bin/node e um wrapper com as flags fixas.
# Com BuildKit + --platform: roda num host amd64 com emulacao arm64 ou num runner arm64 (GitHub Actions).
#
# Uso: build-base-v2.sh <binario node | tarball .tar.xz do release> <tag da base>
#   ex.: build-base-v2.sh dl/node-v24.21.0-linux-arm64-musl-pointer-compression.tar.xz local/node24pc-base:24.21.0-v2
set -eu
SRC=$1; BASE=$2
PLAT=${PLATFORM:-linux/arm64}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
case "$SRC" in
  *.tar.xz) tar -xJf "$SRC" -C "$W" --wildcards '*/bin/node'; mv "$W"/node-*/bin/node "$W/node"; rm -rf "$W"/node-*;;
  *) cp "$SRC" "$W/node";;
esac
cat > "$W/node-wrapper" <<'EOF'
#!/bin/sh
# Node 24 com pointer compression (github.com/rafaelborja/node-pointer-compression-arm64), autocontido em
# /opt/node-pc (loader musl + libstdc++/libgcc_s proprios; roda sobre Alpine e sobre Debian).
# Flags fixas (DECISIONS D-NODE-1/2/3):
#   --max-opt=1              so o tier Sparkplug (sem Maglev/TurboFan): menos RAM de codigo otimizado.
#   --max-old-space-size=64  heap limitado; 64 e o piso medido (48 e 32 nao sobem o Zigbee2MQTT).
#   --max-semi-space-size=2  geracao nova pequena.
# NUNCA --jitless nem --lite-mode: desligam o WebAssembly, e o fetch() do Node (undici) quebra.
exec /opt/node-pc/bin/node --max-opt=1 --max-old-space-size=64 --max-semi-space-size=2 "$@"
EOF
chmod 755 "$W/node" "$W/node-wrapper"
cat > "$W/Dockerfile" <<'EOF'
FROM alpine:3.24 AS prep
RUN apk add --no-cache patchelf libstdc++
COPY node /tmp/node
RUN set -e; mkdir -p /opt/node-pc/bin /opt/node-pc/lib \
 && cp /tmp/node /opt/node-pc/bin/node \
 && cp -L /lib/ld-musl-aarch64.so.1 /usr/lib/libstdc++.so.6 /usr/lib/libgcc_s.so.1 /opt/node-pc/lib/ \
 && ln -s ld-musl-aarch64.so.1 /opt/node-pc/lib/libc.musl-aarch64.so.1 \
 && patchelf --set-interpreter /opt/node-pc/lib/ld-musl-aarch64.so.1 --set-rpath /opt/node-pc/lib /opt/node-pc/bin/node \
 && patchelf --set-rpath /opt/node-pc/lib /opt/node-pc/lib/libstdc++.so.6 \
 && /opt/node-pc/bin/node -e 'console.log("prep ok", process.version)'
FROM scratch
COPY --from=prep /opt/node-pc /opt/node-pc
COPY node-wrapper /usr/bin/node
EOF
docker build --platform "$PLAT" --provenance=false -t "$BASE" "$W"
echo "base $BASE: 1a camada $(docker inspect -f '{{index .RootFS.Layers 0}}' "$BASE")"
