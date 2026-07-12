#!/usr/bin/env node
// Generates .expected snapshots for every .ts case under test/conformance
// by checking each file with the real TypeScript compiler:
//   options: --strict --noEmit --target esnext (default lib).
// Snapshot format: "TS<code> <line>" (1-based), one per diagnostic.
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
};

function walk(dir) {
  const out = [];
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) out.push(...walk(p));
    else if (e.isFile() && e.name.endsWith(".ts")) out.push(p);
  }
  return out;
}

const files = walk(confDir).sort();
let mismatches = 0;
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
  const expPath = file.slice(0, -3) + ".expected";
  const content = lines.length ? lines.join("\n") + "\n" : "";
  if (checkOnly) {
    const existing = fs.existsSync(expPath) ? fs.readFileSync(expPath, "utf8") : "";
    if (existing !== content) {
      mismatches++;
      console.log(`MISMATCH ${file}`);
      console.log(`  tsc:      ${lines.join(", ") || "(clean)"}`);
      console.log(`  snapshot: ${existing.trim().split("\n").filter(Boolean).join(", ") || "(clean)"}`);
    }
  } else {
    if (content) fs.writeFileSync(expPath, content);
    else if (fs.existsSync(expPath)) fs.unlinkSync(expPath);
    console.log(`${path.relative(confDir, file)}: ${lines.join(", ") || "clean"}`);
  }
}
if (checkOnly) {
  console.log(mismatches ? `${mismatches} mismatch(es)` : "all snapshots match tsc");
  process.exit(mismatches ? 1 : 0);
}
