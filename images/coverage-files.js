#!/usr/bin/env node
// Lista (um por linha, ordenada) os arquivos .js/.mjs/.cjs que um app CARREGOU, a partir dos JSON de cobertura do V8
// (NODE_V8_COVERAGE=<dir>, coletados no add-on em execucao). Ignora /opt/node-pc/ (a sonda que coletou a cobertura).
// Uso: node coverage-files.js <dir com coverage-*.json> > loaded-files/<app>.txt
const fs = require("fs"), path = require("path");
const dir = process.argv[2];
if (!dir) { console.error("uso: coverage-files.js <dir>"); process.exit(2); }
const u = new Set();
for (const f of fs.readdirSync(dir).filter((f) => f.endsWith(".json")))
  for (const s of JSON.parse(fs.readFileSync(path.join(dir, f), "utf8")).result || [])
    if (s.url && s.url.startsWith("file://")) {
      const p = decodeURIComponent(s.url.slice(7));
      if (/\.(c|m)?js$/.test(p) && !p.startsWith("/opt/node-pc/")) u.add(p);
    }
process.stdout.write([...u].sort().join("\n") + "\n");
