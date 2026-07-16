#!/usr/bin/env node
// Generates .expected snapshots for every case under test/conformance
// by checking each case with the real TypeScript compiler — the pinned
// native tsgo 7.0.2 baseline (bench/baselines/tsgo; `npm install` there
// if node_modules is missing):
//   options: --strict --noEmit --target esnext --lib esnext,dom
//   (dom purely for `console`), plus module/bundler-resolution options
//   for multi-file cases.
//
// Two case shapes:
//   - single file:  <name>.ts  -> snapshot <name>.expected with lines
//         TS<code> <line>
//   - directory:    <dir>/entry.ts (plus any other files the entry pulls
//     in, incl. a case-local node_modules) -> snapshot <dir>/expected with
//         TS<code> <relative-file> <line>
"use strict";
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const confDir = process.argv[2];
if (!confDir) {
  console.error("usage: gen_expected.js <conformance-dir> [--check]");
  process.exit(2);
}
const checkOnly = process.argv.includes("--check");

// The pinned native compiler (same baseline bench/e2e.sh uses). Pin-checked:
// snapshots are only meaningful against exactly this oracle version.
const ORACLE_VERSION = "7.0.2";
const tsgo = path.join(
  __dirname, "..", "..", "bench", "baselines", "tsgo", "node_modules",
  "@typescript", `typescript-${process.platform}-${process.arch}`, "lib", "tsc",
);
if (!fs.existsSync(tsgo)) {
  console.error(`tsgo baseline not found at ${tsgo}\nrun: cd bench/baselines/tsgo && npm install`);
  process.exit(2);
}
{
  const v = spawnSync(tsgo, ["--version"], { encoding: "utf8" });
  const got = (v.stdout || "").trim().replace(/^Version\s+/, "");
  if (got !== ORACLE_VERSION) {
    console.error(`tsgo version mismatch: want ${ORACLE_VERSION}, got '${got || "(no output)"}' — refusing to run`);
    process.exit(2);
  }
}

// Mirrors the pre-migration programmatic-API options; `--types ""` = types: [].
// esnext ECMAScript globals + the DOM lib (for `console`, which lives in
// lib.dom, not esnext). ztsc's built-in lib (M18.2, re-vendored from the same
// TS 7.0.2 package) is a subset of these, so snapshots stay a fair
// tsgo-vs-ztsc differential. JSX preserve for `.tsx` cases (no effect on
// `.ts`; cases define a self-contained `JSX` namespace, no React types).
const OPTIONS = [
  "--strict", "--noEmit", "--target", "esnext",
  "--lib", "esnext,dom", "--types", "",
  "--module", "esnext", "--moduleResolution", "bundler",
  "--allowImportingTsExtensions", "--jsx", "preserve",
  "--pretty", "false",
];

function walk(dir) {
  // Returns { files: [single-file cases], dirs: [directory cases] }.
  const files = [];
  const dirs = [];
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) {
      if (fs.existsSync(path.join(p, "entry.ts"))) {
        dirs.push(p);
      } else {
        const sub = walk(p);
        files.push(...sub.files);
        dirs.push(...sub.dirs);
      }
    } else if (e.isFile() && (e.name.endsWith(".ts") || e.name.endsWith(".tsx"))) {
      files.push(p);
    }
  }
  return { files, dirs };
}

// `--pretty false` line shape: file(line,col): error TScode: message
const DIAG_RE = /^(.+)\((\d+),(\d+)\): error TS(\d+):/;

// A directory case may carry a tsconfig.json whose `compilerOptions.lib`
// overrides the default `esnext,dom` — this is how the lib_dom cases toggle
// DOM on/off. Returns the OPTIONS with `--lib` replaced (everything else, incl.
// module/bundler resolution, stays identical to every other case), or the
// default OPTIONS when the case has no tsconfig lib. The ztsc conformance
// runner reads the same `lib` (test/run_conformance.zig dirCaseLibSet).
function optionsForDir(dir) {
  const cfgPath = path.join(dir, "tsconfig.json");
  if (!fs.existsSync(cfgPath)) return OPTIONS;
  let lib, skipLibCheck = false;
  let resolveJson = false;
  let allowJs = false;
  let noImplicitAny; // tri-state: undefined = inherit strict
  try {
    const co = JSON.parse(fs.readFileSync(cfgPath, "utf8")).compilerOptions;
    if (co && Array.isArray(co.lib)) lib = co.lib.join(",");
    if (co && co.skipLibCheck === true) skipLibCheck = true;
    if (co && co.resolveJsonModule === true) resolveJson = true;
    if (co && co.allowJs === true) allowJs = true;
    if (co && typeof co.noImplicitAny === "boolean") noImplicitAny = co.noImplicitAny;
  } catch {
    return OPTIONS;
  }
  let out = OPTIONS.slice();
  if (lib) {
    const at = out.indexOf("--lib");
    if (at >= 0) out[at + 1] = lib;
    else out.push("--lib", lib);
  }
  // The ztsc conformance runner reads the same `skipLibCheck` (test/
  // run_conformance.zig dirCaseSkipLibCheck) and suppresses .d.ts diagnostics.
  if (skipLibCheck) out.push("--skipLibCheck");
  // Likewise `resolveJsonModule` (dirCaseBoolOption): keeps the oracle and ztsc
  // in agreement on `*.json` module resolution.
  if (resolveJson) out.push("--resolveJsonModule");
  // `allowJs`: the oracle resolves a JS-only dependency to its `.js` entry (ztsc
  // types it opaquely as `any`; run_conformance.zig dirCaseBoolOption "allowJs").
  if (allowJs) out.push("--allowJs");
  // `noImplicitAny`: default OPTIONS pass `--strict` (which turns it on), so an
  // explicit `false` must be passed to keep the oracle in step with ztsc, which
  // suppresses the implicit-any family (run_conformance.zig no_implicit_any).
  if (noImplicitAny === false) out.push("--noImplicitAny", "false");
  else if (noImplicitAny === true) out.push("--noImplicitAny", "true");
  return out;
}

// All file-anchored diagnostics from one tsgo run, absolute file paths.
// Global (file-less) errors don't match the regex and are skipped, exactly
// as the old programmatic harness skipped diagnostics without file/start.
function runOracle(entryAbs, opts) {
  const r = spawnSync(tsgo, [...(opts || OPTIONS), entryAbs], {
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });
  if (r.error) throw r.error;
  const diags = [];
  for (const line of ((r.stdout || "") + (r.stderr || "")).split("\n")) {
    const m = DIAG_RE.exec(line);
    if (!m) continue;
    diags.push({ file: path.resolve(m[1]), line: +m[2], code: +m[4] });
  }
  return diags;
}

let mismatches = 0;

function emit(expPath, content, label) {
  if (checkOnly) {
    const existing = fs.existsSync(expPath) ? fs.readFileSync(expPath, "utf8") : "";
    if (existing !== content) {
      mismatches++;
      console.log(`MISMATCH ${label}`);
      console.log(`  tsgo:     ${content.trim().split("\n").filter(Boolean).join(", ") || "(clean)"}`);
      console.log(`  snapshot: ${existing.trim().split("\n").filter(Boolean).join(", ") || "(clean)"}`);
    }
  } else {
    if (content) fs.writeFileSync(expPath, content);
    else if (fs.existsSync(expPath)) fs.unlinkSync(expPath);
    console.log(`${label}: ${content.trim().split("\n").filter(Boolean).join(", ") || "clean"}`);
  }
}

const { files, dirs } = walk(confDir);
files.sort();
dirs.sort();

for (const file of files) {
  const abs = path.resolve(file);
  const diags = runOracle(abs).filter((d) => d.file === abs); // lib errors etc.
  diags.sort((a, b) => a.line - b.line || a.code - b.code);
  const lines = diags.map((d) => `TS${d.code} ${d.line}`);
  const content = lines.length ? lines.join("\n") + "\n" : "";
  emit(file.replace(/\.tsx?$/, "") + ".expected", content, path.relative(confDir, file));
}

for (const dir of dirs) {
  const base = path.resolve(dir);
  const diags = runOracle(path.join(base, "entry.ts"), optionsForDir(base))
    .filter((d) => d.file.startsWith(base + path.sep));
  const rows = diags.map((d) => ({
    file: path.relative(base, d.file).split(path.sep).join("/"),
    line: d.line,
    code: d.code,
  }));
  rows.sort((a, b) =>
    a.file < b.file ? -1 : a.file > b.file ? 1 : a.line - b.line || a.code - b.code);
  const lines = rows.map((r) => `TS${r.code} ${r.file} ${r.line}`);
  const content = lines.length ? lines.join("\n") + "\n" : "";
  emit(path.join(dir, "expected"), content, path.relative(confDir, dir));
}

if (checkOnly) {
  console.log(mismatches ? `${mismatches} mismatch(es)` : "all snapshots match tsgo");
  process.exit(mismatches ? 1 : 0);
}
