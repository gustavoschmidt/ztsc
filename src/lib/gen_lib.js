#!/usr/bin/env node
// Assembles ztsc's embedded default libs from a pinned TypeScript package's
// lib/ directory (M18.2 originally by hand from tsc 5.5.4; scripted for the
// TS 7.0.2 oracle migration so the next upgrade is mechanical; extended in
// M21 to also emit the DOM lib so tsconfig `lib` selection is real).
//
//   node src/lib/gen_lib.js <typescript-lib-dir>
//   node src/lib/gen_lib.js bench/baselines/tsgo/node_modules/@typescript/typescript-darwin-arm64/lib
//
// Emits three files next to this script, all @embedFile'd by src/modules.zig:
//
//   lib.esnext.d.ts   the `/// <reference lib="..." />` chain rooted at
//                     lib.esnext.d.ts (deps-first), EXCLUDING the DOM /
//                     webworker / scripthost families. This is the ES-core
//                     surface; always loaded unless --noLib / lib:[].
//   lib.dom.d.ts      the DOM chain (lib.dom + lib.dom.iterable +
//                     lib.dom.asynciterable, deps-first), EXCLUDING its es*
//                     reference deps (lib.dom references es2015 /
//                     es2018.asynciterable, both already in the esnext blob —
//                     DOM is only ever loaded alongside esnext). Provides the
//                     browser globals plus the real `console` (a `Console`).
//   lib.console.d.ts  a minimal `console` shim, loaded ONLY when esnext is
//                     selected WITHOUT dom (e.g. lib:["esnext"], the backend
//                     configuration): `console` lives in lib.dom, not the ES
//                     chain, so without DOM there is no `console` at all. When
//                     DOM is present its richer `Console` is used and this shim
//                     is not loaded (avoids a duplicate `var console`).
"use strict";
const fs = require("fs");
const path = require("path");

const libDir = process.argv[2];
if (!libDir || !fs.existsSync(path.join(libDir, "lib.esnext.d.ts"))) {
  console.error("usage: gen_lib.js <typescript-lib-dir>  (must contain lib.esnext.d.ts)");
  process.exit(2);
}

// Version of the source package, for the provenance header.
function findVersion(dir) {
  let d = path.resolve(dir);
  for (let i = 0; i < 4; i++) {
    const pj = path.join(d, "package.json");
    if (fs.existsSync(pj)) {
      const p = JSON.parse(fs.readFileSync(pj, "utf8"));
      if (p.version) return `${p.name}@${p.version}`;
    }
    d = path.dirname(d);
  }
  return "(unknown version)";
}
const provenance = findVersion(libDir);

const EXCLUDE = /^(dom|webworker|scripthost)($|\.)/;
const DOM_ONLY = /^dom($|\.)/;

// Per-file transforms applied before concatenation.
//
// lib.es2025.iterator.d.ts is authored as a *module* (`export {}` +
// `declare global`) so that upstream can declare an abstract `Iterator`
// class without colliding with the global `Iterator<T>` interface. In tsc
// every lib file is its own SourceFile, so this is invisible; concatenated
// into ztsc's single-file script lib, the top-level `export {}` would turn
// the WHOLE lib into a module and erase every global. Transform: drop the
// `export {};`, rename the module-local `Iterator` scaffolding to a
// `__ztscIteratorAbstract` name that cannot collide (dropping the then
// redundant `globalThis.` qualifier), and unwrap the `declare global`
// block so its declarations are ordinary script globals — exactly the
// surface tsc sees from this file.
const TRANSFORMS = {
  "es2025.iterator": (text) => {
    let t = text;
    const before = t;
    t = t.replace(/^export \{\};\n/m, "");
    t = t.replace(
      /^declare abstract class Iterator</m,
      "declare abstract class __ztscIteratorAbstract<",
    );
    t = t.replace(
      /^interface Iterator<T, TResult, TNext> extends globalThis\.IteratorObject</m,
      "interface __ztscIteratorAbstract<T, TResult, TNext> extends IteratorObject<",
    );
    t = t.replace(/= typeof Iterator;/, "= typeof __ztscIteratorAbstract;");
    // Unwrap `declare global { ... }` — the block closes at the file's
    // final `}`.
    t = t.replace(/^declare global \{\n/m, "");
    t = t.replace(/\}[^}]*$/, "");
    if (
      t === before ||
      /^export \{\};|^declare global \{|globalThis\./m.test(t)
    ) {
      throw new Error("es2025.iterator transform no longer matches upstream — update gen_lib.js");
    }
    return t;
  },
};

// Walk the `/// <reference lib="..." />` chain from `roots` depth-first
// (deps before dependents), keeping only files that pass `keep` and are not
// excluded outright. Returns lib names in deps-first order.
function chain(roots, keep) {
  const order = [];
  const seen = new Set();
  function visit(name) {
    if (seen.has(name)) return;
    seen.add(name);
    const file = path.join(libDir, `lib.${name}.d.ts`);
    const text = fs.readFileSync(file, "utf8");
    for (const m of text.matchAll(/^\/\/\/\s*<reference\s+lib="([^"]+)"\s*\/>/gm)) {
      visit(m[1]);
    }
    if (keep(name)) order.push(name);
  }
  for (const r of roots) visit(r);
  return order;
}

function concat(order) {
  let out = "";
  for (const name of order) {
    const fname = `lib.${name}.d.ts`;
    out += `\n//========== ${fname} ==========\n`;
    let text = fs.readFileSync(path.join(libDir, fname), "utf8");
    if (TRANSFORMS[name]) text = TRANSFORMS[name](text);
    out += text;
  }
  return out;
}

function write(name, header, body) {
  const p = path.join(__dirname, name);
  fs.writeFileSync(p, header + body);
  console.log(`wrote ${p}: ${(header + body).length} bytes`);
}

// --- esnext (ES-core) blob -------------------------------------------------
const esOrder = chain(["esnext"], (n) => !EXCLUDE.test(n));
write(
  "lib.esnext.d.ts",
  `// ZTSC embedded ES-core lib — real TypeScript ES-core..esnext surface.
// Assembled from ${provenance} by src/lib/gen_lib.js — do not edit by hand.
//
// Concatenation of the lib.*.d.ts reference chain rooted at lib.esnext.d.ts
// (${esOrder.length} files, deps-first), with DOM / webworker / scripthost libs excluded
// (those ship as lib.dom.d.ts, loaded via tsconfig \`lib\`). Same pinned
// TypeScript version as the differential oracle, so ztsc and the oracle see
// equivalent globals.
//
// \`console\` is NOT here: it lives in lib.dom. Backend configs (lib:["esnext"])
// get the minimal shim in lib.console.d.ts; DOM configs get lib.dom's Console.
//
// lib.es2025.iterator.d.ts (upstream a module: \`export {}\` + \`declare
// global\`) is rewritten to plain script globals during assembly — see the
// transform note in gen_lib.js.
`,
  concat(esOrder),
);

// --- DOM blob --------------------------------------------------------------
// DOM chain, keeping only the dom.* files (their es* reference deps are
// already in the esnext blob, which DOM is always loaded alongside).
const domOrder = chain(
  ["dom", "dom.iterable", "dom.asynciterable"],
  (n) => DOM_ONLY.test(n),
);
write(
  "lib.dom.d.ts",
  `// ZTSC embedded DOM lib — real TypeScript DOM surface (browser globals).
// Assembled from ${provenance} by src/lib/gen_lib.js — do not edit by hand.
//
// Concatenation of the lib.dom.d.ts chain (${domOrder.length} files, deps-first): the
// browser DOM globals (document, HTMLElement, Response, fetch, URLSearchParams,
// event types, …) plus the real \`console\` (a \`Console\`). The chain's es*
// reference deps (es2015 / es2018.asynciterable) are omitted: DOM is only ever
// loaded together with the esnext blob, which already provides them.
//
// Loaded when tsconfig \`lib\` includes "dom" (or by default, matching tsgo's
// target-esnext default which includes DOM). See src/modules.zig LibSet.
`,
  concat(domOrder),
);

// --- console shim ----------------------------------------------------------
write(
  "lib.console.d.ts",
  `// ZTSC console shim — backend \`console\` (not from DOM).
// Generated by src/lib/gen_lib.js — do not edit by hand.
//
// \`console\` lives in lib.dom, not the ES chain. Loaded ONLY when esnext is
// selected without dom (lib:["esnext"]); DOM configs use lib.dom's richer
// \`Console\` instead, so this shim is not loaded then (no duplicate var).
`,
  `
declare var console: {
    log(...data: any[]): void;
    error(...data: any[]): void;
    warn(...data: any[]): void;
    info(...data: any[]): void;
    debug(...data: any[]): void;
};
`,
);
