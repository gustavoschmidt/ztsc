/// <reference path="./amb.d.ts" />

// A dynamic `import()` is `Promise<<the module's namespace object>>`.
export async function viaAwait() {
  const m = await import("./dyn");
  const a: number = m.value;
  const b = m.default(3);
  const c: number = b.side;
  return [a, c];
}

// ... which also gives the `.then` callback a contextual signature, so its
// parameter is not an implicit any.
export const viaThen = import("./dyn").then((m) => m.value);

// `export =` reaches the export-assigned entity, as `import * as ns` does,
// and interop synthesizes the `default` a CommonJS module has no declaration
// for.
export async function viaExportEquals() {
  const h = await import("./dyneq");
  const s: string = h.run(1);
  const d: string = h.default.run(2);
  return [s, d];
}

// The same, for a module served by an ambient `declare module` block.
export async function viaAmbient() {
  const t = await import("untyped-thing");
  const s: string = t.default(1).go(2);
  return s;
}

// Negative controls.
export async function bad() {
  const m = await import("./dyn");
  const wrong: string = m.value;
  const missing = m.nope;
  const h = await import("./dyneq");
  const badArg = h.run("no");
  return [wrong, missing, badArg];
}
