#!/usr/bin/env node
// Assembles src/lib/lib.esnext.d.ts — ztsc's embedded default lib — from a
// pinned TypeScript package's lib/ directory (M18.2 originally by hand from
// tsc 5.5.4; scripted for the TS 7.0.2 oracle migration so the next upgrade
// is mechanical).
//
//   node src/lib/gen_lib.js <typescript-lib-dir>
//   node src/lib/gen_lib.js bench/baselines/tsgo/node_modules/@typescript/typescript-darwin-arm64/lib
//
// Walks the `/// <reference lib="..." />` chain rooted at lib.esnext.d.ts
// depth-first (deps before dependents — the same deps-first order the header
// documents), excluding the DOM / webworker / scripthost families (ztsc is
// backend-first; tsconfig `lib` selection is post-v0.0.1), concatenates the
// files under `//========== lib.X.d.ts ==========` section markers with the
// upstream copyright headers retained, and appends ztsc's minimal `console`
// shim (`console` lives in lib.dom, not the ES chain; the conformance harness
// gives the oracle lib.dom purely for `console`, so both sides must resolve
// it — see src/modules.zig).
"use strict";
const fs = require("fs");
const path = require("path");

const libDir = process.argv[2];
if (!libDir || !fs.existsSync(path.join(libDir, "lib.esnext.d.ts"))) {
  console.error("usage: gen_lib.js <typescript-lib-dir>  (must contain lib.esnext.d.ts)");
  process.exit(2);
}
const outPath = path.join(__dirname, "lib.esnext.d.ts");

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

const order = []; // lib names, deps-first
const seen = new Set();
function visit(name) {
  if (seen.has(name)) return;
  seen.add(name);
  if (EXCLUDE.test(name)) return;
  const file = path.join(libDir, `lib.${name}.d.ts`);
  const text = fs.readFileSync(file, "utf8");
  for (const m of text.matchAll(/^\/\/\/\s*<reference\s+lib="([^"]+)"\s*\/>/gm)) {
    visit(m[1]);
  }
  order.push(name);
}
visit("esnext");

let out = `// ZTSC embedded lib — real TypeScript ES-core..esnext surface (M18.2).
// Assembled from ${provenance} by src/lib/gen_lib.js — do not edit by hand.
//
// Concatenation of the lib.*.d.ts reference chain rooted at lib.esnext.d.ts
// (${order.length} files, deps-first), with DOM / webworker / scripthost libs excluded
// (ztsc is backend-first; tsconfig \`lib\` selection is post-v0.0.1). This is
// the same pinned TypeScript version as the differential oracle, so ztsc and
// the oracle see equivalent globals.
//
// A minimal \`console\` shim is appended at the end: \`console\` lives in
// lib.dom (not esnext), and the conformance harness gives the oracle lib.dom
// purely for \`console\` — so both sides must resolve it. See src/modules.zig.
//
// lib.es2025.iterator.d.ts (upstream a module: \`export {}\` + \`declare
// global\`) is rewritten to plain script globals during assembly — see the
// transform note in gen_lib.js.
`;

for (const name of order) {
  const fname = `lib.${name}.d.ts`;
  out += `\n//========== ${fname} ==========\n`;
  let text = fs.readFileSync(path.join(libDir, fname), "utf8");
  if (TRANSFORMS[name]) text = TRANSFORMS[name](text);
  out += text;
}

out += `
//========== ztsc console shim (backend \`console\`, not from DOM) ==========
declare var console: {
    log(...data: any[]): void;
    error(...data: any[]): void;
    warn(...data: any[]): void;
    info(...data: any[]): void;
    debug(...data: any[]): void;
};
`;

fs.writeFileSync(outPath, out);
console.log(`wrote ${outPath}: ${order.length} lib files + console shim, ${out.length} bytes (${provenance})`);
