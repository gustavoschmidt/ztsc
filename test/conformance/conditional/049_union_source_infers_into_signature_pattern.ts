// A UNION check type against a single-signature extends clause infers from
// each constituent (tsc's `inferFromTypes`: "source is a union type, infer
// from each constituent type"), and the contravariant candidates combine by
// intersection. That is the whole `UnionToIntersection<U>` idiom.
type UnionToIntersection<U> = (U extends any ? (k: U) => void : never) extends (
  k: infer I,
) => void
  ? I
  : never;

type I2 = UnionToIntersection<{ a: 1 } | { b: 2 }>;
declare const i2: I2;
const i2a: 1 = i2.a;
const i2b: 2 = i2.b;
const i2bad: 2 = i2.a; // TS2322

type I3 = UnionToIntersection<{ a: 1 } | { b: 2 } | { c: 3 }>;
declare const i3: I3;
const i3c: 3 = i3.c;

// The library shape this appears in: a per-key command table folded into one
// object, then indexed by `keyof`.
interface Cmds<R> {
  first: { deleteRange: (n: number) => R };
  second: { focus: () => R; blur: () => R };
}
type ValuesOf<T> = T[keyof T];
type Single = UnionToIntersection<ValuesOf<Cmds<boolean>>>;
declare const s: Single;
const s1: boolean = s.deleteRange(1);
const s2: boolean = s.focus();
const s3: boolean = s.blur();

// A union source still infers covariantly (union, not intersection) when the
// binder sits in a return position.
type Ret<T> = T extends (...a: never[]) => infer R ? R : never;
type R1 = Ret<(() => 1) | (() => 2)>;
declare const r1: R1;
const r1ok: 1 | 2 = r1;
