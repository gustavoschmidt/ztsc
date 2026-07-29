// An intersection SOURCE meets a deferred conditional TARGET whose branches are
// the source itself. No single constituent of the intersection relates to the
// whole conditional, so the "some constituent relates" rule must not answer for
// the pair — the both-branches rule below it must get its turn.
interface Base {
  id: string;
}
type A1 = Base & { type: "a" };
type B1 = Base & { type: "b" };
type E1 = A1 | B1;
declare const e1: E1;
// A UNION OF INTERSECTIONS: the source union distributes to its intersection
// members first, and each one meets the conditional on its own.
export const x1 = <T extends boolean>(): T extends true ? E1 : E1 => e1;

type Base2 = { id: string };
type E2 = (Base2 & { type: "a" }) | (Base2 & { type: "b" });
declare const e2: E2;
export const x2 = <T extends boolean>(): T extends true ? E2 : E2 => e2;

// A branded scalar is the same shape with one constituent.
type Radians = number & { _brand: "radian" };
declare const r: Radians;
export const x3 = <T extends number>(): T extends 0 ? Radians : Radians => r;

// Widening the branches is still fine: `{ a: string }` is a constituent.
type P = { a: string } & { b: number };
declare const p: P;
export const x4 = <T extends boolean>(): T extends true ? { a: string } : { a: string } => p;

// A union of plain objects (no intersection) was never affected.
type E3 = { id: string; type: "a" } | { id: string; type: "b" };
declare const e3: E3;
export const x5 = <T extends boolean>(): T extends true ? E3 : E3 => e3;
