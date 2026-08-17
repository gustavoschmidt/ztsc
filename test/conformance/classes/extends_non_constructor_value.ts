// TS2507 — a heritage expression that carries no CONSTRUCT signature.
//
// tsc's `getBaseConstructorTypeOfClass` accepts only `any` and the null
// widening type outright; everything else has to pass `isConstructorType`.
// The shadowing cases are the ones the corpus names
// (`classExtendsShadowedConstructorFunction`,
// `classExtendsClauseClassNotReferringConstructor`).

class A {
  a: number = 1;
}

namespace Foo {
  const A = 1;
  class B extends A {
    b: string = "";
  }
}

namespace Alpha {
  export const x = 100;
}
class Beta extends Alpha.x {}

function plain() {}
class FromFunction extends plain {}

declare const obj: {};
class FromEmptyObject extends obj {}

// NEGATIVE (must stay clean) -------------------------------------------------

class Ok extends A {}

declare const ctor: new () => A;
class FromCtorType extends ctor {}

declare const anyBase: any;
class FromAny extends anyBase {}

function mixin<T extends new (...args: any[]) => object>(Base: T) {
  return class extends Base {};
}
