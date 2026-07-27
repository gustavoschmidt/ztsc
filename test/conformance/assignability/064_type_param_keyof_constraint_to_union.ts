export {};

declare function takesKey(k: string | number | symbol): void;
declare function takesStr(k: string): void;
declare function takesNum(k: number): void;

// A type parameter whose constraint is a deferred `keyof T` relates to the
// `PropertyKey` union as a WHOLE — no single member of the union accepts it.
function a<T, K extends keyof T>(k: K) {
  takesKey(k);
}

// Already worked: an explicit union constraint, and a bare `keyof T`.
function b<K extends string | number>(k: K) {
  takesKey(k);
}
function c<T>(k: keyof T) {
  takesKey(k);
}

// An intersected key constraint narrows to `string`.
function d<T, K extends keyof T & string>(k: K) {
  takesStr(k);
  takesKey(k);
}

// NEGATIVE: `keyof T` is not `string` — it may still be a number or a symbol.
function e<T, K extends keyof T>(k: K) {
  takesStr(k);
}
function f<T>(k: keyof T) {
  takesNum(k);
}

// NEGATIVE: a constraint that spans neither the union nor any member.
declare function takesAB(x: "a" | "b"): void;
function g<K extends string>(k: K) {
  takesAB(k);
}
function h<K extends "a" | "c">(k: K) {
  takesAB(k);
}
