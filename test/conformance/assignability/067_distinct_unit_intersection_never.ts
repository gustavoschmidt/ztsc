export {};

// tsc's "two distinct unit types" rule (`addTypeToIntersection`): a unit type
// has exactly one value, so an intersection of two different ones is empty.

type A = "line" & "arrow";
type B = 1 & 2;
type C = true & false;
type D = 1n & 2n;
type E = "a" & 1;

declare const a: A;
declare const b: B;
declare const c: C;
declare const d: D;
declare const e: E;

// `never` is assignable to everything: none of these is an error.
const ra: { z: 1 } = a;
const rb: { z: 1 } = b;
const rc: { z: 1 } = c;
const rd: { z: 1 } = d;
const re: { z: 1 } = e;

// The motivating shape: a refining intersection distributes over the union it
// refines, and the dead arm has to disappear or an exhaustive `switch` leaves
// residue in its default branch.
type Base = { id: string };
type Linear = Base & { type: "line" | "arrow" };
type Arrow = Linear & { type: "arrow" };
type Text = Base & { type: "text" };
type El = Linear | Arrow | Text;

declare function assertNever(x: never): void;

export function kind(el: El): number {
  const t = el.type;
  switch (t) {
    case "line":
      return 0;
    case "arrow":
      return 1;
    case "text":
      return 2;
    default:
      assertNever(t);
      return -1;
  }
}

// NEGATIVE: the SAME unit type twice is one unit, not two — it stays itself.
type F = "line" & "line";
declare const f: F;
const rf: { z: 1 } = f;
const rf2: "line" = f;

// NEGATIVE: object types are not units — two of them intersect normally.
type J = { x: 1 } & { y: 2 };
declare const j: J;
const rj: { x: 1; y: 2 } = j;
const rk: { z: 1 } = j;
