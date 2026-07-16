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

// --- sharding ---------------------------------------------------------------
// The big blobs (esnext ~0.6 MB, dom ~2.35 MB) are split into N shard files so
// the front end (scan → parse → bind) parallelizes across worker threads
// instead of running one giant file serially on a single worker. Splits happen
// only at TOP-LEVEL DECLARATION BOUNDARIES — never inside an interface / class
// / module / `declare global` body — so each shard is an independently
// parseable sequence of ambient declarations. ztsc parses/binds each shard as
// its own SourceFile and the linker merges their globals exactly as if they
// were one file (cross-file declaration merging already works, and this is in
// fact how tsc itself sees the lib: one SourceFile per lib.*.d.ts).
//
// Byte-preserving: concatenating a blob's shards reproduces the un-sharded body
// exactly, and the provenance header rides on shard 0 ONLY, so the un-sharded
// `header + body` byte stream is reproduced verbatim across the shard set —
// line/byte/token/node totals are unchanged; only the file COUNT grows (which
// is the point). Keep the shard counts in sync with src/modules.zig
// (es_shard_count / dom_shard_count).
const ES_SHARDS = 4;
const DOM_SHARDS = 8;

// Split `body` into `k` slices at top-level declaration boundaries, balanced by
// byte size; `slices.join("") === body` exactly. A cut lands at the start of a
// top-level declaration line (column-0 `interface` / `declare` / `type` / … —
// member lines inside a body are always indented, so a column-0 keyword is
// always top-level — and never inside a block comment), backed up over any
// immediately preceding comment/blank trivia so a doc-comment travels with the
// declaration it annotates instead of being orphaned onto the previous shard.
function splitAtDeclBoundaries(body, k) {
  if (k <= 1) return [body];
  const lines = body.split("\n");
  const off = new Array(lines.length + 1);
  off[0] = 0;
  for (let i = 0; i < lines.length; i++) off[i + 1] = off[i] + lines[i].length + 1;

  const DECL = /^(?:export\s+)?(?:declare|interface|type|abstract|class|function|namespace|enum|const|var|let)\b/;
  const declStart = new Array(lines.length).fill(false);
  const trivia = new Array(lines.length).fill(false);
  let inBlock = false; // inside a /* … */ block comment (TS block comments don't nest)
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const startedInBlock = inBlock;
    if (!startedInBlock && DECL.test(line)) declStart[i] = true;
    const t = line.trim();
    // A line is trivia (carried forward with the following declaration) when it
    // holds no top-level code: a comment-block continuation/close (startedIn-
    // Block), a blank line, a `//`/`///` line, or a `/*`/`/**` block-comment
    // opener (whose body/closer follow on later trivia lines). Marking the
    // OPENER as trivia is what keeps a whole JSDoc block with its declaration —
    // otherwise the cut lands after `/**`, splitting mid-comment.
    if (startedInBlock || t === "" || t.startsWith("//") || t.startsWith("/*")) trivia[i] = true;
    // Advance block-comment state (TS block comments don't nest): stay in-block
    // until a `*/` closes; enter a block at the last unterminated `/*`.
    if (startedInBlock) {
      inBlock = !line.includes("*/");
    } else {
      const o = line.lastIndexOf("/*");
      inBlock = o !== -1 && line.indexOf("*/", o) === -1;
    }
  }

  // Candidate cut offsets: each top-level declaration start, backed up over its
  // leading trivia run. Strictly increasing (each decl start is code).
  const candidates = [];
  for (let i = 0; i < lines.length; i++) {
    if (!declStart[i]) continue;
    let j = i;
    while (j - 1 >= 0 && trivia[j - 1]) j--;
    candidates.push(off[j]);
  }

  const total = off[lines.length];
  const chosen = [];
  let last = 0;
  for (let s = 1; s < k; s++) {
    const target = Math.round((total * s) / k);
    let best = -1, bestd = Infinity;
    for (const c of candidates) {
      if (c <= last) continue;
      const d = Math.abs(c - target);
      if (d < bestd) { bestd = d; best = c; }
    }
    if (best < 0) throw new Error(`not enough declaration boundaries to split into ${k} shards`);
    chosen.push(best);
    last = best;
  }

  const slices = [];
  let prev = 0;
  for (const c of chosen) { slices.push(body.slice(prev, c)); prev = c; }
  slices.push(body.slice(prev));
  // Invariant checks (cheap, guard the determinism/byte-preservation contract).
  if (slices.length !== k) throw new Error("shard count mismatch");
  if (slices.join("") !== body) throw new Error("shards do not reconstitute the body");
  // Every shard after the first must begin at a clean top-level boundary: a
  // declaration keyword, a comment/reference, or a blank line — never an
  // indented line (mid-body) or a bare `*`/`*/` (mid-block-comment). This
  // catches any boundary that would split an interface body or a JSDoc block,
  // which would corrupt the shard when parsed on its own.
  const CLEAN_START = /^(?:\s*$|\/\/|\/\*|\*|(?:export\s+)?(?:declare|interface|type|abstract|class|function|namespace|enum|const|var|let)\b)/;
  for (let i = 1; i < slices.length; i++) {
    const first = slices[i].slice(0, slices[i].indexOf("\n") + 1 || slices[i].length);
    if (/^[ \t]/.test(first) || first.startsWith("*")) {
      throw new Error(`shard ${i} starts mid-body/mid-comment: ${JSON.stringify(first.slice(0, 60))}`);
    }
    if (!CLEAN_START.test(first)) {
      throw new Error(`shard ${i} does not start at a top-level boundary: ${JSON.stringify(first.slice(0, 60))}`);
    }
  }
  return slices;
}

function writeShards(base, header, body, k) {
  const slices = splitAtDeclBoundaries(body, k);
  for (let i = 0; i < k; i++) {
    const name = `${base}.${i}.d.ts`;
    const content = i === 0 ? header + slices[i] : slices[i];
    fs.writeFileSync(path.join(__dirname, name), content);
    console.log(`wrote ${name}: ${content.length} chars${i === 0 ? " (+header)" : ""}`);
  }
}

// Remove any previously generated esnext/dom files (old single-file blobs and
// prior shard sets) so regeneration is clean and deterministic. The console
// shim (lib.console.d.ts) is kept.
for (const f of fs.readdirSync(__dirname)) {
  if (/^lib\.(esnext|dom)(\.\d+)?\.d\.ts$/.test(f)) fs.unlinkSync(path.join(__dirname, f));
}

// --- esnext (ES-core) blob -------------------------------------------------
const esOrder = chain(["esnext"], (n) => !EXCLUDE.test(n));
writeShards(
  "lib.esnext",
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
  ES_SHARDS,
);

// --- DOM blob --------------------------------------------------------------
// DOM chain, keeping only the dom.* files (their es* reference deps are
// already in the esnext blob, which DOM is always loaded alongside).
const domOrder = chain(
  ["dom", "dom.iterable", "dom.asynciterable"],
  (n) => DOM_ONLY.test(n),
);
writeShards(
  "lib.dom",
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
  DOM_SHARDS,
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
