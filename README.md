# node-pointer-compression-arm64

Builds do Node.js **com V8 pointer compression** para **linux arm64 musl (Alpine)** — que ninguém publica pronto
para o Node 24 LTS. Uso: add-ons Node do Home Assistant (Zigbee2MQTT, Z-Wave JS UI, Matter Server) num HAOS aarch64
com pouca RAM. Medido (Node 25.8.2, mesma versão com e sem PC, heap 128): −21 a −24% de heap V8, −12 a −27 MB de
RSS por processo.

- Fonte: tarball oficial de nodejs.org, checksum conferido. Sem patches.
- `./configure --experimental-enable-pointer-compression` (cage compartilhada desde nodejs/node#58171, v24.2.0):
  limite de 4 GB de heap por processo; addons Node-API funcionam, NAN/V8-API precisam de rebuild.
- Rodar: Actions → build-node-pointer-compression → Run workflow (versão, ex.: `v24.21.0`). O resultado vira uma release.
