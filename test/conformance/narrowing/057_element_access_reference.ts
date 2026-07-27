// A CONSTANT element access (`arr[0]`) is a narrowing reference, exactly like
// a dotted member: a guard written on it narrows the reads of the same access.
// A variable index is not a stable reference and narrows nothing.
type R = { type: "rect"; a: number };
type I = { type: "image"; a: number };
declare function isImage(e: R | I): e is I;
declare function sink(f: I): void;

declare const arr: (R | I)[];
declare const tup: [R | I, R | I];
declare const narr: (I | null)[];
let i = 0;

// user-defined type guard
export function a() {
  if (isImage(arr[0])) {
    sink(arr[0]);
  }
}

// discriminant equality
export function b() {
  if (arr[0].type === "image") {
    sink(arr[0]);
  }
}

// truthiness
export function c() {
  if (narr[0]) {
    sink(narr[0]);
  }
}

// tuple element
export function d() {
  if (isImage(tup[1])) {
    sink(tup[1]);
  }
}

// deeper path: a property of a narrowed element
type W = { items: (R | I)[] };
declare const w: W;
export function e() {
  if (isImage(w.items[0])) {
    sink(w.items[0]);
  }
}

// NEGATIVE: a MUTABLE index is not a stable reference
export function f() {
  if (isImage(arr[i])) {
    i = i + 1;
    sink(arr[i]); // TS2345
  }
}

// NEGATIVE: a different constant index is a different reference
export function g() {
  if (isImage(arr[0])) {
    sink(arr[1]); // TS2345
  }
}

// NEGATIVE: writing the reference invalidates the narrowing
declare const marr: (R | I)[];
declare const anyEl: R | I;
export function h() {
  if (isImage(marr[0])) {
    marr[0] = anyEl;
    sink(marr[0]); // TS2345
  }
}

// NEGATIVE: writing a PREFIX of the reference invalidates it
export function k() {
  let mw: W = w;
  if (isImage(mw.items[0])) {
    mw = w;
    sink(mw.items[0]); // TS2345
  }
}

// NEGATIVE: the false branch keeps the other constituent
export function l() {
  if (isImage(arr[0])) {
    return;
  }
  sink(arr[0]); // TS2345
}
