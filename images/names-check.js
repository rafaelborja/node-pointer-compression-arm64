#!/usr/bin/env node
// Confere que a fonte limpa nao muda o .name de nenhuma funcao, classe ou metodo.
// Para cada par (original, limpo) compara, na ordem do codigo, o NOME EFETIVO de cada funcao/classe/metodo como o V8
// o define ou infere: declaracao (function f / class C), expressao nomeada, `const f = () => {}`, `x = function(){}`,
// `{ m() {} }`, `{ k: () => {} }`, campos de classe, parametro com default -- e, na saida com --keep-names, o nome
// fixado por `__name(fn, "x")` / `static { __name(this, "x") }` (o helper `__name` em si e ignorado).
//
// Por que: mesmo sem minificar identificadores, o esbuild RENOMEIA funcoes/classes cujo nome sombreia outro (padrao de
// decorators do TS: `let X = (() => { ... X = class ... })()` -> `X2`), e sem --keep-names `AlarmSensorCC.name` vira
// "AlarmSensorCC2" em runtime. O clean-tree.sh usa este script para decidir, por arquivo, se precisa de --keep-names.
// Outros identificadores renomeados (parametro `Status` -> `Status2` no padrao de enum) nao mudam .name: so contados.
//
// Uso:
//   node names-check.js <lista de originais> <prefixo original> <prefixo limpo>   relatorio; sai 1 se algum nome muda
//   node names-check.js --pairs < "orig<TAB>limpo" por linha                     imprime os LIMPOS com nome mudado
//                                                                                  (ou que nao parseiam)
// Requer o pacote acorn (NODE_PATH ou node_modules).
"use strict";
const fs = require("fs");
const acorn = require("acorn");
const keyName = (k, computed) => (computed ? null : k.type === "Identifier" || k.type === "PrivateIdentifier" ? k.name : k.type === "Literal" ? String(k.value) : null);
const isFn = (n) => n && /^(FunctionExpression|ArrowFunctionExpression|ClassExpression)$/.test(n.type);
const isNameCall = (n) => n && n.type === "CallExpression" && n.callee.type === "Identifier" && n.callee.name === "__name" &&
  n.arguments.length === 2 && n.arguments[1].type === "Literal" && typeof n.arguments[1].value === "string";
function parse(src) {
  src = src.replace(/^#!.*/, "");
  let err;
  for (const sourceType of ["module", "script"]) {
    try { return acorn.parse(src, { ecmaVersion: "latest", sourceType, allowReturnOutsideFunction: true,
      allowHashBang: true, allowAwaitOutsideFunction: true, allowImportExportEverywhere: true }); } catch (e) { err = e; }
  }
  throw err;
}
function analyze(src) {
  const ast = parse(src);
  const entries = [], ids = [], inferred = new Map(), fixed = new Map(), fixedById = new Map(), varFn = new Map();
  (function walk(n) {
    if (!n || typeof n !== "object") return;
    if (Array.isArray(n)) { for (const x of n) walk(x); return; }
    if (n.type === "VariableDeclarator" && n.id.type === "Identifier") {
      if (isFn(n.init)) inferred.set(n.init, n.id.name);
      else if (isNameCall(n.init) && isFn(n.init.arguments[0])) inferred.set(n.init.arguments[0], n.id.name);
    }
    if (n.type === "AssignmentExpression" && n.left.type === "Identifier") {
      if (isFn(n.right)) inferred.set(n.right, n.left.name);
      else if (isNameCall(n.right) && isFn(n.right.arguments[0])) inferred.set(n.right.arguments[0], n.left.name);
    }
    if (n.type === "AssignmentPattern" && n.left.type === "Identifier" && isFn(n.right)) inferred.set(n.right, n.left.name);
    if (n.type === "Property" || n.type === "MethodDefinition" || n.type === "PropertyDefinition") {
      const v = isNameCall(n.value) && isFn(n.value.arguments[0]) ? n.value.arguments[0] : n.value;
      if (isFn(v)) inferred.set(v, keyName(n.key, n.computed) ?? "<computed>");
    }
    if (n.type === "VariableDeclarator" && n.id.type === "Identifier" && isFn(n.init)) varFn.set(n.id.name, n.init);
    if (isNameCall(n)) {  // __name(fn, "x") | __name(ident, "x") | __name(this, "x") (dentro de static {})
      const t = n.arguments[0], lit = n.arguments[1].value;
      if (isFn(t)) fixed.set(t, lit);
      else if (t.type === "Identifier") fixedById.set(t.name, lit);
    }
    if (n.type === "ClassDeclaration" || n.type === "ClassExpression") {
      for (const el of n.body.body) if (el.type === "StaticBlock")
        for (const st of el.body) if (st.type === "ExpressionStatement" && isNameCall(st.expression) &&
          st.expression.arguments[0].type === "ThisExpression") fixed.set(n, st.expression.arguments[1].value);
    }
    if (/^(FunctionDeclaration|FunctionExpression|ArrowFunctionExpression|ClassDeclaration|ClassExpression)$/.test(n.type))
      entries.push(n);
    if ((n.type === "Identifier" || n.type === "PrivateIdentifier") && n.name !== "undefined") ids.push(n.name);
    for (const k in n) if (n[k] && typeof n[k] === "object") walk(n[k]);
  })(ast);
  // `let f2 = function(){}; __name(f2, "f")` (funcao de bloco reescrita pelo esbuild) -> vale o nome fixado
  for (const [id, lit] of fixedById) if (varFn.has(id) && !fixed.has(varFn.get(id))) fixed.set(varFn.get(id), lit);
  const fns = [];
  for (const n of entries) {
    let name = n.id ? n.id.name : inferred.get(n) ?? "";
    if (name === "__name" || name === "__defProp") continue;   // o helper que o --keep-names injeta
    if (fixed.has(n)) name = fixed.get(n);
    else if (n.id && n.type === "FunctionDeclaration" && fixedById.has(n.id.name)) name = fixedById.get(n.id.name);
    fns.push(name);
  }
  return { fns, ids: ids.filter((x) => x !== "__name" && x !== "__defProp") };
}
const eq = (a, b) => a.length === b.length && a.every((x, i) => x === b[i]);
// Compara como MULTICONJUNTO (a ordem pode mudar: o esbuild move declaracoes de funcao de bloco).
// mudado = um nome que existia no original sumiu (virou outro) -> FALHA.
// ganho  = funcao anonima no original (.name "") que o --keep-names batizou (p.ex. `var x = a || function(){}`,
//          onde o V8 nao infere nome e o __name() do esbuild poe "x") -> inofensivo, contado a parte.
function compare(f, g) {
  const a = analyze(fs.readFileSync(f, "utf8")), b = analyze(fs.readFileSync(g, "utf8"));
  const cnt = new Map(); for (const x of a.fns) cnt.set(x, (cnt.get(x) || 0) + 1);
  const added = []; for (const x of b.fns) { const c = cnt.get(x) || 0; if (c) cnt.set(x, c - 1); else added.push(x); }
  const removed = []; for (const [x, c] of cnt) for (let i = 0; i < c; i++) removed.push(x);
  const removedNamed = removed.filter((x) => x !== "");
  const other = !eq(a.ids, b.ids);
  if (!removedNamed.length && !added.length) return { ok: true, n: a.fns.length, other };
  if (!removedNamed.length && added.every((x) => x !== "")) return { ok: true, gained: added, n: a.fns.length, other };
  return { ok: false, n: a.fns.length, why: `sumiram=${JSON.stringify(removed.slice(0, 5))} apareceram=${JSON.stringify(added.slice(0, 5))}` };
}
module.exports = { analyze, compare };
if (require.main === module) {
  if (process.argv[2] === "--pairs") {
    for (const l of fs.readFileSync(0, "utf8").split("\n").filter(Boolean)) {
      const [f, g] = l.split("\t");
      try { if (!compare(f, g).ok) console.log(g); } catch { console.log(g); }   // nao parseia -> conservador
    }
  } else {
    const [list, pa, pb] = process.argv.slice(2);
    let ok = 0, bad = 0, err = 0, nf = 0, other = 0, gained = 0;
    for (const f of fs.readFileSync(list, "utf8").split("\n").filter(Boolean)) {
      const g = pb + f.slice(pa.length);
      let r;
      try { r = compare(f, g); } catch (e) { err++; console.log("ERRO-PARSE", f, e.message); continue; }
      nf += r.n;
      if (r.ok) { ok++; if (r.other) other++; if (r.gained) { gained++; console.log("NOME-GANHO", g, JSON.stringify(r.gained)); } continue; }
      bad++; console.log("NOME-DIFERE", f, r.why);
    }
    console.log(`arquivos: nomes-iguais=${ok} nomes-diferentes=${bad} erro-de-parse=${err} anonimas-batizadas-pelo-keep-names=${gained} | funcoes/classes conferidas=${nf}` +
      ` | arquivos com outro identificador renomeado (nao e nome de funcao)=${other}`);
    process.exit(bad || err ? 1 : 0);
  }
}
