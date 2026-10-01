#!/usr/bin/env node
// Config de runtime da imagem oficial -> instrucoes de Dockerfile, e a conferencia ESTRITA de que a imagem nova saiu
// com a mesma config. Le a saida de `docker image inspect --platform <plat> <img>` (um array JSON) de arquivos.
//
//   node image-config.js dockerfile <oficial.json>              -> ENV/LABEL/USER/WORKDIR/EXPOSE/VOLUME/STOPSIGNAL/
//                                                                   SHELL/HEALTHCHECK/ENTRYPOINT/CMD
//   node image-config.js compare <oficial.json> <nova.json>     -> sai 1 e lista as diferencas
//
// Por que existe (2026-09-24): a zwave-js-ui oficial e um indice multi-plataforma; no image store do containerd,
// `docker inspect` SEM --platform devolveu uma config VAZIA (Entrypoint null, sem ENV, sem LABEL) e a imagem nova
// saiu sem ENTRYPOINT ["/init"] -> o Supervisor recusou ("[400] no command specified"). Por isso: inspect sempre com
// --platform, tudo copiado explicitamente, e a comparacao nao tolera diferenca em Entrypoint/Cmd (nem no resto).
"use strict";
const fs = require("fs");
const load = (f) => { const j = JSON.parse(fs.readFileSync(f, "utf8")); return (Array.isArray(j) ? j[0] : j).Config || {}; };
// valor entre aspas numa instrucao do Dockerfile: escapa \ " e $ (o Dockerfile expande $VAR em ENV/LABEL/WORKDIR...)
const q = (s) => '"' + String(s).replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\$/g, "\\$") + '"';
const ns = (n) => `${n}ns`; // duracoes do inspect vem em nanossegundos; o Dockerfile aceita "123ns"
const [mode, a, b] = process.argv.slice(2);

if (mode === "dockerfile") {
  const c = load(a), out = [];
  for (const e of c.Env || []) { const i = e.indexOf("="); out.push(`ENV ${e.slice(0, i)}=${q(e.slice(i + 1))}`); }
  for (const [k, v] of Object.entries(c.Labels || {})) out.push(`LABEL ${q(k)}=${q(v)}`);
  if (c.User) out.push(`USER ${c.User}`);
  out.push(`WORKDIR ${c.WorkingDir || "/"}`);
  for (const p of Object.keys(c.ExposedPorts || {})) out.push(`EXPOSE ${p}`);
  if (c.Volumes && Object.keys(c.Volumes).length) out.push(`VOLUME ${JSON.stringify(Object.keys(c.Volumes))}`);
  if (c.StopSignal) out.push(`STOPSIGNAL ${c.StopSignal}`);
  if (c.Shell) out.push(`SHELL ${JSON.stringify(c.Shell)}`);
  const h = c.Healthcheck;
  if (h && h.Test && h.Test.length) {
    if (h.Test[0] === "NONE") out.push("HEALTHCHECK NONE");
    else {
      const o = [];
      if (h.Interval) o.push(`--interval=${ns(h.Interval)}`);
      if (h.Timeout) o.push(`--timeout=${ns(h.Timeout)}`);
      if (h.StartPeriod) o.push(`--start-period=${ns(h.StartPeriod)}`);
      if (h.StartInterval) o.push(`--start-interval=${ns(h.StartInterval)}`);
      if (h.Retries) o.push(`--retries=${h.Retries}`);
      const cmd = h.Test[0] === "CMD-SHELL" ? h.Test[1] : JSON.stringify(h.Test.slice(1));
      out.push(`HEALTHCHECK ${o.join(" ")} CMD ${cmd}`.replace(/  +/g, " "));
    }
  }
  // ENTRYPOINT zera o CMD herdado; por isso os dois sao escritos SEMPRE (o valor [] / null vira "sem" explicitamente)
  out.push(`ENTRYPOINT ${JSON.stringify(c.Entrypoint || [])}`);
  out.push(`CMD ${JSON.stringify(c.Cmd || [])}`);
  process.stdout.write(out.join("\n") + "\n");
} else if (mode === "compare") {
  const o = load(a), n = load(b), bad = [];
  const norm = (k, v) => {
    if (v === undefined || v === null) v = null;
    if ((k === "Entrypoint" || k === "Cmd") && Array.isArray(v) && v.length === 0) v = null;
    if (k === "WorkingDir" && (v === "" || v === null)) v = "/";
    if ((k === "ExposedPorts" || k === "Volumes") && v && !Object.keys(v).length) v = null;
    if (k === "User" || k === "StopSignal") v = v || "";
    if (k === "Healthcheck" && v) v = Object.fromEntries(Object.entries(v).filter(([, x]) => x !== 0 && x !== null));
    return JSON.stringify(v);
  };
  if (!o.Entrypoint && !o.Cmd) bad.push("a OFICIAL nao tem Entrypoint nem Cmd -- inspect sem --platform num indice multi-arch?");
  for (const k of ["Entrypoint", "Cmd", "User", "Env", "WorkingDir", "ExposedPorts", "Volumes", "StopSignal", "Shell", "Healthcheck"]) {
    const x = norm(k, o[k]), y = norm(k, n[k]);
    if (x !== y) bad.push(`Config.${k}: nova=${y} oficial=${x}`);
  }
  for (const [k, v] of Object.entries(o.Labels || {}))
    if ((n.Labels || {})[k] !== v) bad.push(`Label ${k}: nova=${JSON.stringify((n.Labels || {})[k])} oficial=${JSON.stringify(v)}`);
  if (bad.length) { console.log(bad.join("\n")); process.exit(1); }
  console.log("config identica a oficial (Entrypoint/Cmd/User/Env/WorkingDir/ExposedPorts/Volumes/StopSignal/Shell/Healthcheck/Labels)");
} else { console.error("uso: image-config.js dockerfile <oficial.json> | compare <oficial.json> <nova.json>"); process.exit(2); }
