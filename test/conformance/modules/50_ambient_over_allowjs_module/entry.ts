/// <reference path="./shims.d.ts" />
// `png-lite` is an untyped JavaScript-only package. Under `allowJs` the
// specifier resolves to `node_modules/png-lite/index.js`, which ztsc loads as
// a synthetic opaque `any` module (`declare const j: any; export = j;`) — and
// that placeholder `export =` used to answer the import BEFORE the real
// ambient `declare module "png-lite"` block, silently degrading every use to
// `any`. tsc looks an exactly-named ambient module up in the globals first, so
// the declaration must win.
//
// Each line below is silent if the `any` module wins and diagnosed if the
// ambient declaration wins, so the snapshot itself is the assertion.
import decode from "png-lite";

export const n: number = decode("x"); // ok — the declared return type
export const bad: string = decode("x"); // TS2322 — `number` is not `string`
export const arity = decode(); // TS2554 — the declared signature takes one arg
