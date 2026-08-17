// TS2698 — tsc's `isValidSpreadType` on `{ ...x }`.
//
// The ORDER of its two rewrites is what this pins: a type parameter is
// replaced by its CONSTRAINT first, and only then are the definitely-falsy
// constituents dropped. So `T | (T & undefined)` and `object | T` for
// `T extends undefined` both spread fine, while a bare `undefined` — reduced
// to `never` — does not.

declare const u: undefined;
declare const n: null;
declare const k: unknown;
declare const v: void;
declare const b: boolean;
declare const s: symbol;
declare const num: number;
declare const str: string;
declare const t: true;
declare const z: 0;
declare const es: "";
declare const nu: null | undefined;

export const a1 = { ...u };
export const a2 = { ...n };
export const a3 = { ...k };
export const a4 = { ...v };
export const a5 = { ...b };
export const a6 = { ...s };
export const a7 = { ...num };
export const a8 = { ...str };
export const a9 = { ...t };
export const a10 = { ...z };
export const a11 = { ...es };
export const a12 = { ...nu };

export function f1<T>(x: T & undefined) {
  return { ...x };
}
export function f3<T extends undefined>(x: T) {
  return { ...x };
}

// NEGATIVE (must stay clean) -------------------------------------------------

declare const nonprim: object;
declare const fn: () => void;
declare const arr: number[];
declare const ou: { a: 1 } | undefined;
declare const on: { a: 1 } | null;

export const c1 = { ...nonprim };
export const c2 = { ...fn };
export const c3 = { ...arr };
export const c4 = { ...ou };
export const c5 = { ...on };

export function g1<T>(x: T) {
  return { ...x };
}
export function g2<T>(x: T | (T & undefined)) {
  return { ...x };
}
export function g3<T extends undefined>(x: object | T) {
  return { ...x };
}
export function g4<S, T extends undefined>(x: S | T) {
  return { ...x };
}
export function g5<T extends object | undefined>(x: T) {
  return { ...x };
}
export function g6<T extends {}, A extends { z: (T | undefined) & T }>(x: A) {
  const { z } = x;
  return { ...z };
}
