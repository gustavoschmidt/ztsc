// tsc's `getTypeWithSyntheticDefaultImportType`: under
// allowSyntheticDefaultImports a module that declares no `default` of its own
// still hands `import("m")` one — the module namespace object itself —
// SPREAD over the module type, so the named exports stay reachable too.
//
// ztsc synthesized that default only for a STATIC default import and only
// for an `export =` module through `import()`, so
// `(await import('@emoji-mart/data')).default` — a `.d.ts` of nothing but
// interfaces — was a false TS2339 on an empty namespace object.

import type { Data } from "./typesonly";

// A declaration file exporting only types: the namespace object is empty,
// and the synthesized default is that same object.
export async function typesOnly(): Promise<Data> {
  const m = await import("./typesonly");
  return m.default as Data;
}

// With named exports, the spread keeps them AND adds the default.
export async function named() {
  const m = await import("./named");
  const n: number = m.named;
  const s: string = m.go(1);
  const viaDefault: number = m.default.named;
  return [n, s, viaDefault];
}

// A real source module's OWN default is untouched.
export async function realDefault() {
  const m = await import("./hasdefault");
  const s: string = m.default(1);
  const o: number = m.other;
  return [s, o];
}

// NEGATIVE — a real source module with ES-module syntax and no default gets
// no synthetic one.
export async function bad() {
  const m = await import("./nodefault");
  return m.default;
}
