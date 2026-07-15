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

// All file-anchored diagnostics from one tsgo run, absolute file paths.
// Global (file-less) errors don't match the regex and are skipped, exactly
// as the old programmatic harness skipped diagnostics without file/start.
function runOracle(entryAbs) {
  const r = spawnSync(tsgo, [...OPTIONS, entryAbs], {
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
  const diags = runOracle(path.join(base, "entry.ts"))
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
