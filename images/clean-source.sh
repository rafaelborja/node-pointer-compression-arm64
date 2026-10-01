#!/bin/sh
# "Fonte limpa" (pc3): aplica clean-tree.sh (esbuild) aos .js/.mjs/.cjs do add-on e poe SO os arquivos que mudaram
# numa camada nova por cima da imagem pc2. Lista: ALL = todo .js/.mjs/.cjs sob as raizes (padrao dos builds publicos:
# generico, nao depende de nenhuma instalacao); ou um arquivo com um caminho por linha (ex.: a lista que coverage-files.js
# tira da cobertura V8 de um add-on rodando -- uso local, nao publicar). A camada-base (node) continua a primeira e a mesma.
# O esbuild roda NATIVO (estagio --platform=$BUILDPLATFORM): o JS de saida nao depende da arquitetura.
# --keep-names so nos arquivos em que o esbuild mudaria um nome (decisao por arquivo no clean-tree.sh); a lista fica
# em /opt/node-pc/clean-keepnames-<app>.txt na imagem. No fim, names-check.js confere TODOS os arquivos da lista
# contra os originais: se algum nome de funcao/classe/metodo mudou, o build FALHA.
#
# Uso: clean-source.sh <imagem pc2> <ALL | lista de arquivos> <tag de saida> <raiz> [<raiz> ...]
#   raiz = diretorio da imagem que contem os arquivos da lista (copiado para o estagio do esbuild)
#   ex.: clean-source.sh local/z2m-pc2:2.14.1-1 loaded-files/z2m.txt local/z2m-pc3:2.14.1-1 /app
# Env: CLEAN_EXCLUDE = regex (grep -E) de caminhos a NAO transformar (exclusoes achadas pelo portao de testes).
#      JOBS = paralelismo do esbuild (padrao 8).
set -eu
SRC=$1; LIST=$2; DST=$3; shift 3
PLAT=${PLATFORM:-linux/arm64}; JOBS=${JOBS:-8}; X=${CLEAN_EXCLUDE:-}
HERE=$(cd "$(dirname "$0")" && pwd)
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
if [ "$LIST" = ALL ]; then : > "$W/files.txt"; n=$(echo "${DST##*/}" | sed 's/-pc3.*//; s/:.*//')
else tr -d '\r' < "$LIST" > "$W/files.txt"; n=$(basename "$LIST" .txt); fi
for f in clean-tree.sh names-check.js; do tr -d '\r' < "$HERE/$f" > "$W/$f"; done
# script do estagio de limpeza (sem expansao aqui: heredoc com aspas)
cat > "$W/stage.sh" <<'EOF'
#!/bin/sh
set -eu
n=$1; jobs=$2; x=$3
# originais dos arquivos da lista, para a conferencia final de nomes
mkdir -p /orig /out/opt/node-pc
cd /work
# lista vazia = ALL: todo .js/.mjs/.cjs copiado das raizes
[ -s /files.txt ] || find . -type f \( -name '*.js' -o -name '*.mjs' -o -name '*.cjs' \) | sed 's#^\.##' | sort > /files.txt
echo "arquivos na lista: $(wc -l < /files.txt)"
sed 's#^/##' /files.txt | while IFS= read -r f; do [ -f "$f" ] && echo "$f"; done > /rel.txt
tar cf - -T /rel.txt | tar xf - -C /orig
cd /
sh /clean-tree.sh -j "$jobs" -p /work -o /out -s /resumo.txt -k /out/opt/node-pc/clean-keepnames-$n.txt -x "$x" < /files.txt
# conferencia final: NENHUM nome de funcao/classe/metodo mudou (falha o build se mudou)
sed 's#^#/orig/#' /rel.txt > /orig.txt
if ! node /names-check.js /orig.txt /orig/ /work/ > /names.txt; then grep -v '^arquivos:' /names.txt | head -20; tail -1 /names.txt; exit 1; fi
echo "$(cat /resumo.txt) esbuild=$(cat /esbuild-version) nomes: $(tail -1 /names.txt)" > /out/opt/node-pc/clean-resumo-$n.txt
cat /out/opt/node-pc/clean-resumo-$n.txt
EOF
{
  echo "FROM $SRC AS src"
  echo 'FROM --platform=$BUILDPLATFORM alpine:3.24 AS clean'
  echo "RUN apk add --no-cache esbuild nodejs npm && npm i -g acorn@8.18.0 >/dev/null && esbuild --version > /esbuild-version"
  echo "ENV NODE_PATH=/usr/local/lib/node_modules"
  for r in "$@"; do echo "COPY --from=src $r /work$r"; done
  echo "COPY files.txt clean-tree.sh names-check.js stage.sh /"
  echo "RUN sh /stage.sh $n $JOBS '$X'"
  echo "FROM $SRC"
  echo "COPY --from=clean /out/ /"
  echo "LABEL io.github.rafaelborja.node-clean=\"esbuild --charset=ascii --legal-comments=inline --minify-whitespace --target=esnext --platform=node, + --keep-names so nos arquivos em que o esbuild mudaria um nome (lista em /opt/node-pc/clean-keepnames-$n.txt); lista: $( [ "$LIST" = ALL ] && echo 'todos os .js/.mjs/.cjs' || echo 'arquivos carregados'); exclusoes: ${X:-nenhuma}\""
} > "$W/Dockerfile"
cat "$W/Dockerfile"
docker build --platform "$PLAT" --provenance=false -t "$DST" "$W"
echo "$DST: $(MSYS_NO_PATHCONV=1 docker run --rm --platform "$PLAT" --entrypoint cat "$DST" /opt/node-pc/clean-resumo-$n.txt)"
