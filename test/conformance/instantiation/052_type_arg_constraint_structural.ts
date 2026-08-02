// The deliberate boundary of TS2344 (see the DEFERRED entry). The check
// decides a written type argument only against a constraint that is a
// PRIMITIVE OR LITERAL SET; everything below is left undecided on purpose, so
// that a gap in some other part of the checker can never surface as an
// invented error on valid code.

// (1) Decided — a literal set, and an intersection of one with a primitive.
type Key<K extends "a" | "b"> = K;
type NarrowKey<K extends string & ("a" | "b")> = K;
declare const k1: Key<"zz">;
declare const k2: NarrowKey<"zz">;

// (2) Not decided — a STRUCTURAL constraint. `isAssignable` would answer, but
// only as well as the structural relation does, and that is not evidence
// enough for a negative verdict.
interface Shape {
  n: number;
}
type Holder<T extends Shape> = T[];
declare const h1: Holder<Shape>;
declare const h2: Holder<{ s: string }>;

// (3) Not decided — the ARGUMENT is a deferred node (an indexed access into a
// still-free type parameter), not a set ztsc can enumerate.
type Pick1<K extends "a" | "b"> = K;
type Wrap<T extends { k: "zz" }> = Pick1<T["k"]>;
declare const w1: Wrap<{ k: "zz" }>;

// The use site still reports, whatever this check decided.
declare function take(k: "a" | "b"): void;
export const u = take("zz");
