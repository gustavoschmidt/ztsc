// An intersection of callables is ONE overload set: tsc's
// `resolveIntersectionTypeMembers` concatenates every constituent's call
// signatures, in member order, into a single list the call resolves against.
// Keeping only the first callable constituent silently discarded every
// signature the others carried.

interface A {
  f(x: number): number;
}
interface B {
  f(x: string): string;
}
declare const ab: A & B;
export const r1: number = ab.f(1);
export const r2: string = ab.f("s");
export const r3 = ab.f(true); // TS2769: neither constituent accepts a boolean

// The same for a bare intersection of function types...
type F1 = (x: number) => number;
type F2 = (x: string) => string;
declare const g: F1 & F2;
export const g1: number = g(1);
export const g2: string = g("s");

// ...and for constituents that carry their call signatures on an interface.
interface C1 {
  (x: number): "n";
  tag: string;
}
interface C2 {
  (x: string): "s";
}
declare const cc: C1 & C2;
export const c1: "n" = cc(1);
export const c2: "s" = cc("x");
export const c3: string = cc.tag;

// A non-callable constituent contributes nothing but does not make the
// intersection uncallable.
declare const mixed: F1 & { note: string };
export const m1: number = mixed(1);
export const m2: string = mixed.note;

// Nothing callable at all is still TS2349.
declare const dead: { a: number } & { b: string };
export const d1 = dead();
