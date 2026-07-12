#!/usr/bin/env node
// Generates .expected snapshots for every case under test/conformance
// by checking each case with the real TypeScript compiler:
//   options: --strict --noEmit --target esnext (default lib),
//   plus module/bundler-resolution options for multi-file cases.
//
// Two case shapes:
//   - single file:  <name>.ts  -> snapshot <name>.expected with lines
//         TS<code> <line>
//   - directory:    <dir>/entry.ts (plus any other files the entry pulls
//     in, incl. a case-local node_modules) -> snapshot <dir>/expected with
//         TS<code> <relative-file> <line>
"use strict";
const ts = require("typescript");
const fs = require("fs");
const path = require("path");

const confDir = process.argv[2];
if (!confDir) {
  console.error("usage: gen_expected.js <conformance-dir> [--check]");
  process.exit(2);
}
const checkOnly = process.argv.includes("--check");

const options = {
  strict: true,
  noEmit: true,
  target: ts.ScriptTarget.ESNext,
  lib: ["lib.esnext.d.ts"],
  types: [],
  module: ts.ModuleKind.ESNext,
  moduleResolution: ts.ModuleResolutionKind.Bundler,
  allowImportingTsExtensions: true,
};

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
    } else if (e.isFile() && e.name.endsWith(".ts")) {
      files.push(p);
    }
  }
  return { files, dirs };
}

function diagLines(program, filterDir, relBase) {
  const lines = [];
  for (const sf of program.getSourceFiles()) {
    const abs = path.resolve(sf.fileName);
    if (filterDir && !abs.startsWith(path.resolve(filterDir) + path.sep)) continue;
    const diags = [
      ...program.getSyntacticDiagnostics(sf),
      ...program.getSemanticDiagnostics(sf),
    ];
    for (const d of diags) {
      if (d.file === undefined || d.start === undefined) continue;
      if (d.file.fileName !== sf.fileName) continue;
      const { line } = d.file.getLineAndCharacterOfPosition(d.start);
      const rel = path.relative(relBase, abs).split(path.sep).join("/");
      lines.push({ file: rel, line: line + 1, code: d.code });
    }
  }
  lines.sort((a, b) =>
    a.file < b.file ? -1 : a.file > b.file ? 1 : a.line - b.line || a.code - b.code);
  return lines.map((l) => `TS${l.code} ${l.file} ${l.line}`);
}

let mismatches = 0;

function emit(expPath, content, label) {
  if (checkOnly) {
    const existing = fs.existsSync(expPath) ? fs.readFileSync(expPath, "utf8") : "";
    if (existing !== content) {
      mismatches++;
      console.log(`MISMATCH ${label}`);
      console.log(`  tsc:      ${content.trim().split("\n").filter(Boolean).join(", ") || "(clean)"}`);
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
  const program = ts.createProgram([file], options);
  const sf = program.getSourceFile(file);
  const diags = [
    ...program.getSyntacticDiagnostics(sf),
    ...program.getSemanticDiagnostics(sf),
  ];
  const lines = [];
  for (const d of diags) {
    if (d.file === undefined || d.start === undefined) continue;
    if (d.file.fileName !== sf.fileName) continue; // lib errors etc.
    const { line } = d.file.getLineAndCharacterOfPosition(d.start);
    lines.push(`TS${d.code} ${line + 1}`);
  }
  const content = lines.length ? lines.join("\n") + "\n" : "";
  emit(file.slice(0, -3) + ".expected", content, path.relative(confDir, file));
}

for (const dir of dirs) {
  const entry = path.join(dir, "entry.ts");
  const program = ts.createProgram([entry], options);
  const lines = diagLines(program, dir, dir);
  const content = lines.length ? lines.join("\n") + "\n" : "";
  emit(path.join(dir, "expected"), content, path.relative(confDir, dir));
}

if (checkOnly) {
  console.log(mismatches ? `${mismatches} mismatch(es)` : "all snapshots match tsc");
  process.exit(mismatches ? 1 : 0);
}
