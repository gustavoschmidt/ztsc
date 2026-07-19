// Instantiating a generic *interface* that carries a call/construct signature
// must substitute the type params inside the signature (not drop it): the
// resulting object stays callable. Models jest's `Mock<T, Y, C>` whose call
// signature is `(this: C, ...args: Y): T`. Before the fix, `B<any, any>` lost
// its signature (or kept it unsubstituted) and was not assignable to any
// concrete function type.
interface B<T, Y extends any[]> {
  (...args: Y): T;
}
declare const b: B<any, any>;
const fb: (id: string) => number = b; // clean: (...args:any):any accepts it

// Construct signature through the same path.
interface Ctor<T> {
  new (x: number): T;
}
declare const mk: Ctor<{ v: string }>;
const c1: new (x: number) => { v: string } = mk; // clean
const c2: new (x: number) => { v: number } = mk; // TS2322 (v:string not v:number)

// jest-like Mock with a `this` param on its call signature and a generic
// method (mockImplementation) inherited from a generic base interface.
interface MockInstance<T, Y extends any[], C> {
  mockImplementation(fn: (...args: Y) => T): this;
}
interface Mock<T, Y extends any[], C> extends MockInstance<T, Y, C> {
  (this: C, ...args: Y): T;
}
declare function fn<T, Y extends any[], C = any>(): Mock<T, Y, C>;

// The instantiated call signature (with its `this` param) is assignable to a
// concrete function type; the return type is enforced.
const handler: (id: string) => number = fn<number, [string]>(); // clean
const bad: (id: string) => string = fn<number, [string]>(); // TS2322: number ret not string

// The inherited generic method survives instantiation and chains (returns
// `this`, i.e. the instantiated Mock).
const m = fn<number, [string]>();
const chained: Mock<number, [string], any> = m.mockImplementation((id: string) => id.length); // clean
