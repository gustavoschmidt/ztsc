// A class's STATIC side is an ordinary object type — the statics plus a
// construct signature — so `typeof Sub` relates to `typeof Base` structurally,
// exactly like any other pair of object types. ztsc used to answer NO for
// every pair of DISTINCT class values, because the identity fast path covers
// only the same symbol and the nominal heritage walk relates instance sides.
//
// The visible cost was a whole family of TS2684: a static generic method
// written `static m<T extends typeof Base>(this: T, …)` — the
// react-native-reanimated animation-builder idiom — could not infer `T` from
// the receiver, so `T` fell back to its constraint and the `this` check
// reported that fallback against the real receiver.

declare class Base {
  static tag: string;
  x: number;
  static make<T extends typeof Base>(this: T, n: number): InstanceType<T>;
}
declare class Mid extends Base {
  static extraStatic: number;
}
declare class Leaf extends Mid {
  y: number;
}

// direct static-side assignment, one and two levels of `extends`
export const a: typeof Base = Mid;
export const b: typeof Base = Leaf;
export const c: typeof Mid = Leaf;

// the `this`-parameter call this was found through: `T` infers from the
// receiver, so the return is the RECEIVER's instance type, not the base's
export const d = Leaf.make(1);
export const e: Leaf = Leaf.make(1);
export const f: Base = Mid.make(1);

// a structural object with the right construct signature is still assignable
// to a class value (the direction that already worked)
export const g: typeof Base = {
  tag: "t",
  make: Base.make,
  prototype: Base.prototype,
} as unknown as typeof Base;

// NEGATIVES — the relation stays structural, so it still says no.
// A base is not assignable to its derived static side: `extraStatic` missing.
export const h: typeof Mid = Base;

// An unrelated class with an incompatible static is not assignable either.
declare class Other {
  static tag: number;
  x: number;
  static make<T extends typeof Base>(this: T, n: number): InstanceType<T>;
}
export const i: typeof Base = Other;

// A derived class whose CONSTRUCTOR demands more arguments than the base's is
// genuinely not assignable to the base's static side — the reason this has to
// be a structural comparison and not a "is it a subclass" shortcut.
declare class Ctor {
  constructor(a: number);
  static tag: string;
}
declare class WiderCtor extends Ctor {
  constructor(a: number, b: string);
}
export const j: typeof Ctor = WiderCtor;
