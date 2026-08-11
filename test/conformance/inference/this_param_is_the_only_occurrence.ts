// A signature may name a type parameter in its `this` type and NOWHERE else:
//
//   static springify<T extends typeof ComplexAnimationBuilder>(
//     this: T, duration?: number): ComplexAnimationBuilder;
//
// (react-native-reanimated). `instantiateId`'s `.function` arm substitutes the
// `this` type, but the `containsTypeParam` early-out that decides whether that
// arm runs at all only looked at the return type, the parameters and the type
// predicate. So the signature was judged concrete, instantiation returned it
// untouched, and the receiver check compared `typeof ZoomIn` against a still
// free `T` — TS2684, even though inference from the receiver (tsc's
// `getThisArgumentType` feeding `inferTypeArguments`) had a candidate for it.
//
// Every method below is a correct call and must be silent.

declare class A {
  static n: number;
  // `T` in the return as well: this shape always worked.
  static withRet<T extends typeof A>(this: T, d?: number): InstanceType<T>;
  // `T` ONLY in `this` — the regression.
  static noRet<T extends typeof A>(this: T, d?: number): A;
  static noArgs<T extends typeof A>(this: T): A;
  static voidRet<T extends typeof A>(this: T, d?: number): void;
}

declare class B extends A {}
declare class C extends B {}

export const a1: InstanceType<typeof A> = A.withRet(1);
export const a2: A = A.noRet(1);
export const a3: A = A.noArgs();
A.voidRet(1);

export const b1: B = B.withRet(1);
export const b2: A = B.noRet(1);
export const b3: A = B.noArgs();
B.voidRet(1);

export const c1: C = C.withRet(1);
export const c2: A = C.noRet(1);

// The same on a plain object type, and through a chained call whose receiver
// is itself the result of one.
interface Box {
  n: number;
  tag<T extends Box>(this: T, s: string): void;
  self<T extends Box>(this: T): T;
}
declare const box: Box;
box.tag("x");
box.self().tag("y");

// A `this` type that is a bare type parameter of the ENCLOSING generic
// interface, not of the signature, still substitutes through the reference.
interface Holder<V> {
  v: V;
  put<T extends Holder<V>>(this: T, v: V): void;
}
declare const hs: Holder<string>;
hs.put("s");

export { A, B, C };
