// `reactish` publishes an `exports` map naming only JavaScript — both for the
// root and for a subpath — and its declarations live in a SEPARATE package,
// `@types/reactish`. This is react's exact shape.
//
// A package's own JavaScript may only be reached after the DefinitelyTyped
// fallback has missed at every `node_modules` level. Probing it as soon as the
// map's declaration targets miss lands on `reactish/index.js`, types the whole
// surface `any`, and buries the real errors below (and reports TS7016 where
// tsgo is silent).
import { createElement } from "reactish";
import { jsx } from "reactish/jsx-runtime";

export const n: number = createElement("div"); // ok — @types/reactish
export const b: boolean = jsx("div"); // ok — @types/reactish subpath

export const bad: string = createElement("div"); // TS2322 — not `any`
export const badSub: string = jsx("div"); // TS2322 — not `any`
export const arity = createElement(); // TS2554 — the declared signature
