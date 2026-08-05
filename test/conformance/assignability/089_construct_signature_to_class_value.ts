// A class's STATIC side is an ordinary object type in tsc — its statics plus
// one construct signature per constructor overload — so any object carrying a
// matching construct signature is assignable to `typeof C`. ztsc models a
// class value nominally (`new C()` and `C.staticMember` read the symbol
// directly) and the assignability arm for a `.class_value` TARGET simply
// answered no, so the `ClassConstructor<T> = { new (...args: any[]): T }`
// interface every DI container is written around was not a `typeof Service`.
// immich's `test/medium.factory.ts` is that shape twice over
// (`BASE_SERVICE_DEPENDENCIES.includes(dep)`).

interface ClassConstructor<T = any> {
  new (...args: any[]): T;
}

class A {
  a = 1;
  constructor(x: number) {
    void x;
  }
}
class B {
  b = 2;
  constructor(y: string) {
    void y;
  }
}

declare const anyCtor: ClassConstructor<any>;
declare const aCtor: ClassConstructor<A>;
declare const bare: new (...args: any[]) => any;

export const r1: typeof A = anyCtor;
export const r2: typeof A = aCtor;
export const r3: typeof A = bare;
export const r4: typeof A | typeof B = anyCtor;

// The `includes(searchElement: T)` shape the app actually writes.
declare function includes<T>(list: T[], value: T): boolean;
declare const deps: (typeof A | typeof B)[];
export const r5 = includes(deps, anyCtor);

// A class value still satisfies its own construct-signature interface, which
// is the direction that already worked.
export const r6: ClassConstructor<A> = A;

// Statics on the target are real requirements, and a source that has them
// passes.
class S {
  static make(): S {
    return new S();
  }
  s = 1;
}
declare const sCtor: { new (...args: any[]): S; make(): S };
export const r7: typeof S = sCtor;

export {};
