# node-pointer-compression-arm64

Builds do Node.js **com V8 pointer compression** para **linux arm64 musl (Alpine)**.

## Por que compilar

- **Ninguém publica isso pronto para o Node 24 LTS em arm64 musl.** O `nodejs/unofficial-builds` só tem pointer
  compression para x64/riscv64; o `platformatic/node-caged` só para Node 25/26; o único build 24 arm64 com PC que
  existe (sublimelsp) é glibc, 24.15, e traz patches do Electron.
- **Segurança:** o Node 25 chegou ao fim de vida em 2026-06-01 e os builds 25.x/26.1 prontos estão sem as correções
  HIGH de junho/julho de 2026. O Node 24 é LTS até abril de 2028.
- **Compatibilidade:** o Zigbee2MQTT exige Node `<=26.2` (o `serialport` quebra no 26.3+), então o 26.x corrigido
  não serve; o 24 LTS serve.
- **O PC no Node 24 funciona** desde nodejs/node#58171 (v24.2.0), com cage compartilhada: limite de 4 GB de heap por
  processo — irrelevante para daemons de ~100 MB.

## O que se ganha (medido)

Home Assistant OS numa VM aarch64 de 4 GB (Pixel 8 Pro), add-ons Zigbee2MQTT, Z-Wave JS UI e Matter Server.
Mesma versão do Node (25.8.2, node-caged), com e sem PC, heap 128 MB: **−21 a −24% de heap V8, −12 a −27 MB de RSS
por processo**; com heap 60 MB o Zigbee2MQTT só sobe **com** PC. O Node 25 sem PC gasta o mesmo que o 24.

## Sabores

| flavor | `./configure` | para quê |
|---|---|---|
| `pc` | `--experimental-enable-pointer-compression` | o ganho medido acima |
| `slim` | `pc` + `--with-intl=small-icu --without-inspector --without-sqlite --without-amaro` | menos código mapeado: ICU só em inglês, sem depurador, sem `node:sqlite`, sem o removedor de tipos TypeScript. **Mantém WebAssembly** (o CI confere) |
| ~~`lean`~~ | `pc` + `--v8-lite-mode …` | **descartado:** o V8 em lite-mode é compilado **sem WebAssembly** (o build falha em `bad option: --experimental-wasm-jspi`), e o `fetch()` do Node (undici) depende de WebAssembly |

Fonte: tarball oficial de nodejs.org, checksum conferido contra `SHASUMS256.txt`. Sem patches. Addons Node-API
(ex.: `@serialport/bindings-cpp`) funcionam; addons NAN/API V8 direta precisam de rebuild.

Rodar: Actions → build-node-pointer-compression → Run workflow (versão e flavor). O resultado vira uma release.

## Não use `--jitless` nem `--lite-mode` para economizar

Os dois desligam o **WebAssembly**, e o `fetch()` do Node (undici) usa WebAssembly para interpretar HTTP:
`fetch` falha com `ReferenceError: WebAssembly is not defined`. Num Home Assistant isso quebrou, sem nenhum
aviso visível, a consulta do Matter Server ao DCL (atualizações de firmware, dados de fabricantes) e a checagem de
firmware do Z-Wave JS. Para cortar o JIT de JavaScript **mantendo** o WebAssembly, use `--max-opt=0` (só o
interpretador) ou `--max-opt=1` — atenção: `--max-opt` não é aceito em `NODE_OPTIONS`, só na linha de comando.

## Imagens dos add-ons sobre uma camada comum (`build-addon-images`)

O workflow `images.yml` pega as imagens **oficiais** do Zigbee2MQTT e do Z-Wave JS UI e troca só o `/usr/bin/node`:
as duas passam a começar na mesma camada-base, que contém o Node pointer compression deste repo. Camada igual no
overlay2 = mesmo inode = o kernel guarda **uma** cópia do binário na memória, em vez de uma por add-on. O
`/usr/bin/node` vira um wrapper com `--max-opt=1 --max-old-space-size=64 --max-semi-space-size=2` — os limites
medidos no HAOS do projeto (64 MB é o piso; 48 e 32 não sobem o Zigbee2MQTT). Nada de `--jitless`/`--lite-mode`.

Saída: um release com um único `docker save` das três imagens (a camada comum vai uma vez só). O app dentro de cada
imagem é byte a byte o da imagem oficial; ver `images/build-images.sh`.
