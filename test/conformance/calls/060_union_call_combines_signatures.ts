// Calling a UNION is not overload resolution over the constituents'
// signatures: tsc's `getUnionSignatures` COMBINES the lists
// (`combineSignaturesOfUnionMembers`) into one signature whose parameters
// are the position-wise INTERSECTION of the constituents' and whose return
// type is their UNION. Picking the first constituent's signature instead
// typed every callback parameter after the first constituent alone.

interface A {
  go(cb: (v: {a: number}) => void): number;
}
interface B {
  go(cb: (v: {b: string}) => void): string;
}
declare const ab: A | B;

// The callback parameter is contextually `{a:number} & {b:string}` — an
// intersection of two call signatures — which collapses back to the union
// `{a:number} | {b:string}` for the arrow's parameter.
ab.go(v => {
  if ("a" in v) {
    const n: number = v.a;
    return n;
  }
  const s: string = v.b;
  return s;
});

// The combined return type is the union of the constituents'.
export const r: number | string = ab.go(() => {});

// A union of bare function types combines the same way.
type F1 = (cb: (v: number) => void) => void;
type F2 = (cb: (v: string) => void) => void;
declare const f: F1 | F2;
f(v => {
  if (typeof v === "number") {
    const n: number = v;
    return n;
  }
  const s: string = v;
  return s;
});

// Generic signatures: the right constituent's type parameters are mapped
// onto the left's, so both sides speak the same `U`.
interface L1 {
  map<U>(cb: (v: number) => U): U[];
}
interface L2 {
  map<U>(cb: (v: string) => U): U[];
}
declare const l: L1 | L2;
export const mapped: boolean[] = l.map(v => typeof v === "number");

// Non-callback parameters intersect too, so an argument has to satisfy
// BOTH constituents.
interface P1 {
  take(x: {a: number}): void;
}
interface P2 {
  take(x: {b: string}): void;
}
declare const p: P1 | P2;
p.take({a: 1, b: "s"} as {a: number} & {b: string});
p.take({a: 1}); // TS2345: satisfies P1 alone, not the intersection

// A union whose constituents share one signature keeps it intact.
interface S1 {
  same(x: number): number;
}
interface S2 {
  same(x: number): number;
}
declare const s: S1 | S2;
export const sr: number = s.same(1);
