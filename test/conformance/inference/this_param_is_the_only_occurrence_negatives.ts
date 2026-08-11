// Guard rails on `this_param_is_the_only_occurrence`. Teaching
// `containsTypeParam` about the `this` slot makes such a signature
// instantiable, which is the direction that can HIDE a receiver error, so
// every way TS2684 must still fire is pinned here.

declare class A {
  static n: number;
  static noRet<T extends typeof A>(this: T, d?: number): A;
  static voidRet<T extends typeof A>(this: T, d?: number): void;
}

// An unrelated receiver does not satisfy `T extends typeof A`: `typeof Other`
// has no `n`, so the inferred `T` is clamped to the constraint and the
// receiver is measured against it.
declare class Other {
  static m: string;
  static noRet: (typeof A)["noRet"];
}
Other.noRet(1);

// Detached and called with no receiver at all: `void` is not `typeof A`.
const f2: (d?: number) => A = A.noRet;
void f2;

// A `this` constraint the receiver misses by a property.
interface Box {
  n: number;
  tag<T extends Box>(this: T, s: string): void;
}
declare const notBox: { m: number; tag: Box["tag"] };
notBox.tag("x");

// A `this` type that is NOT a type parameter still has to be checked.
interface Fixed {
  n: number;
  hit(this: { n: number; extra: string }): void;
}
declare const fixed: Fixed;
fixed.hit();

// The inferred `T` is used: a receiver whose own property type conflicts is
// still rejected where `T` flows into a parameter.
interface Pair<V> {
  v: V;
  set<T extends Pair<V>>(this: T, v: V): void;
}
declare const ps: Pair<string>;
ps.set(1);

export { A, notBox, fixed, ps };
