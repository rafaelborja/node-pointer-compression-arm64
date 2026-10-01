#!/bin/sh
# clean-tree.sh -- a transformacao "fonte limpa", IN PLACE, arquivo por arquivo. E a UNICA definicao dela: o build das
# imagens (clean-source.sh) e o portao de testes (tests/) chamam este script, entao o que se testa e o que se publica.
#
# Por que: o V8 guarda o TEXTO de todo script carregado (para compilar funcoes sob demanda); um unico caractere fora do
# Latin-1 (um travessao num comentario) faz o arquivo inteiro ficar em UTF-16 (2 bytes/caractere). E o Z2M liga source
# maps (process.setSourceMapsEnabled), o Matter roda com --enable-source-maps.
# O que faz, por arquivo .js/.mjs/.cjs (esbuild, sem bundle, formato ESM/CJS preservado):
#   --charset=ascii          escapa o que nao e ASCII (strings, regex, identificadores) -> o V8 guarda 1 byte/caractere
#   --legal-comments=inline  mantem os comentarios de licenca (/*! */, @license, @preserve); os demais somem
#   --minify-whitespace      so espaco em branco; nao encurta identificadores
#   --target=esnext --platform=node
#   --keep-names             SO NOS ARQUIVOS QUE PRECISAM (decisao por arquivo, desde 2026-09-24):
#     mesmo sem minificar identificadores, o esbuild RENOMEIA funcoes/classes cujo nome sombreia outro (padrao de
#     decorators do TS: `let X = (() => { ... X2 = class ... })()`) -> sem --keep-names, `AlarmSensorCC.name` vira
#     "AlarmSensorCC2". Mas o --keep-names poe __name() em TODA funcao/closure, inclusive em lacos quentes (+14% de
#     tempo no matter.js, 3 timeouts no FabricManager). Entao: 1) esbuild SEM --keep-names; 2) names-check.js compara o
#     nome efetivo de cada funcao/classe/metodo com o original; 3) se algum mudou (ou nao parseia), refaz o arquivo COM
#     --keep-names. Resultado: nenhum .name muda e __name() so onde e preciso.
# Some tambem o //# sourceMappingURL -> nenhum mapa e carregado. Arquivo que o esbuild recusa fica como esta.
# Grava por cima com `cat >` (mantem dono, modo e inode do original; o `mv` da versao do VM perdia o +x).
#
# Uso:  clean-tree.sh [opcoes] < lista      (um caminho por linha)
#       clean-tree.sh [opcoes] -d DIR ...   (todo .js/.mjs/.cjs sob DIR)
#   -j N      processos em paralelo (padrao 1)
#   -x REGEX  (grep -E) caminhos que NAO sao transformados -- as exclusoes do portao de testes
#   -s ARQ    grava o resumo (limpos/com_keep_names/falhas/excluidos/bytes) tambem em ARQ
#   -k ARQ    grava a lista dos arquivos que precisaram de --keep-names (a decisao por arquivo)
#   -p PFX    prefixo acrescentado a cada caminho da lista (ex.: /work, quando a arvore foi copiada para /work)
#   -o DIR    alem de gravar in place, copia cada arquivo transformado para DIR<caminho> (com o dono/modo do diretorio
#             de origem) -> uma camada com SO os arquivos que mudaram
# Requer: esbuild (env ESBUILD; imagens: 0.27.1 do apk do alpine:3.24), node e o pacote acorn (NODE_PATH) para o
# names-check.js que fica ao lado deste script (env NAMES_CHECK para outro caminho).
set -u
es(){ f=$1; shift; "$CT_ESBUILD" "$f" --log-level=error --charset=ascii --legal-comments=inline --minify-whitespace \
        --target=esnext --platform=node "$@" 2>>"$CT_T/err.$$"; }
if [ "${1:-}" = --one ]; then            # modo interno: xargs chama com um lote de arquivos
  shift
  : > "$CT_T/pairs.$$"
  for p in "$@"; do
    case "$p" in *.js|*.mjs|*.cjs) ;; *) continue;; esac
    [ -f "$p" ] || continue
    if [ -n "$CT_X" ] && printf '%s\n' "$p" | grep -Eq -- "$CT_X"; then echo "x 0 0 $p"; continue; fi
    if es "$p" --outfile="$p.clean"; then printf '%s\t%s\n' "$p" "$p.clean" >> "$CT_T/pairs.$$"
    else rm -f "$p.clean"; b=$(wc -c < "$p"); echo "bad $b $b $p"; fi
  done
  [ -s "$CT_T/pairs.$$" ] || exit 0
  # nomes: o que mudou (ou nao parseia) e refeito com --keep-names
  node "$CT_NAMES" --pairs < "$CT_T/pairs.$$" > "$CT_T/kn.$$" || { echo "names-check falhou" >&2; exit 255; }
  while IFS= read -r c; do
    p=${c%.clean}
    if ! es "$p" --keep-names --outfile="$c"; then rm -f "$c"; fi
  done < "$CT_T/kn.$$"
  cut -f1 "$CT_T/pairs.$$" | while IFS= read -r p; do
    b=$(wc -c < "$p")
    [ -f "$p.clean" ] || { echo "bad $b $b $p"; continue; }
    cat "$p.clean" > "$p"; rm -f "$p.clean"; a=$(wc -c < "$p")
    if grep -qxF "$p.clean" "$CT_T/kn.$$"; then echo "kn $b $a $p"; else echo "ok $b $a $p"; fi
    if [ -n "$CT_O" ]; then rel=${p#"$CT_P"}; d=$(dirname "$rel"); mkdir -p "$CT_O$d"; cp -p "$p" "$CT_O$rel"; fi
  done
  exit 0
fi
J=1; X=''; SUM=''; DIRS=''; PFX=''; OUT=''; KN=''
while getopts j:x:s:d:p:o:k: o; do
  case $o in j) J=$OPTARG;; x) X=$OPTARG;; s) SUM=$OPTARG;; d) DIRS="$DIRS $OPTARG";; p) PFX=$OPTARG;; o) OUT=$OPTARG;;
    k) KN=$OPTARG;; *) echo "uso: veja o cabecalho" >&2; exit 2;; esac
done
CT_T=$(mktemp -d); CT_X=$X; CT_O=$OUT; CT_P=$PFX; CT_ESBUILD=${ESBUILD:-esbuild}
CT_NAMES=${NAMES_CHECK:-$(cd "$(dirname "$0")" && pwd)/names-check.js}
export CT_T CT_X CT_O CT_P CT_ESBUILD CT_NAMES
"$CT_ESBUILD" --version >/dev/null || { echo "esbuild nao encontrado" >&2; exit 1; }
node -e 'require("acorn")' || { echo "node + acorn sao necessarios (NODE_PATH?)" >&2; exit 1; }
[ -f "$CT_NAMES" ] || { echo "names-check.js nao encontrado: $CT_NAMES" >&2; exit 1; }
if [ -n "$DIRS" ]; then
  # shellcheck disable=SC2086
  find $DIRS -type f \( -name '*.js' -o -name '*.mjs' -o -name '*.cjs' \)
else
  while IFS= read -r f; do [ -n "$f" ] && printf '%s%s\n' "$PFX" "$f"; done
fi | tr '\n' '\0' | xargs -0 -r -n 64 -P "$J" sh "$0" --one > "$CT_T/res" || { echo "ERRO no lote (names-check?)" >&2; rm -rf "$CT_T"; exit 1; }
if [ -n "$OUT" ]; then   # diretorios criados em OUT ficam com dono/modo dos de origem (COPY para / os sobrescreve)
  find "$OUT" -mindepth 1 -type d | while IFS= read -r d; do
    s="$PFX${d#"$OUT"}"; [ -d "$s" ] || continue
    chown "$(stat -c %u:%g "$s")" "$d" 2>/dev/null; chmod "$(stat -c %a "$s")" "$d"
  done
fi
r=$(awk '{n[$1]++; b+=$2; a+=$3} END {printf "limpos=%d com_keep_names=%d falhas=%d excluidos=%d bytes_antes=%d bytes_depois=%d", n["ok"]+n["kn"], n["kn"], n["bad"], n["x"], b, a}' "$CT_T/res")
echo "$r"; [ -n "$SUM" ] && echo "$r" > "$SUM"
[ -n "$KN" ] && { grep '^kn ' "$CT_T/res" | cut -d' ' -f4- | sed "s#^$PFX##" | sort > "$KN"; }
if cat "$CT_T"/err.* 2>/dev/null | grep -q .; then echo "--- erros do esbuild (arquivos mantidos como estavam):" >&2; cat "$CT_T"/err.* >&2; fi
grep '^bad ' "$CT_T/res" | cut -d' ' -f4- | sed 's/^/falhou: /' >&2
rm -rf "$CT_T"
