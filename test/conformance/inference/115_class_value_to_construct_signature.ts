// Inference from a CLASS VALUE (`typeof C`) to a parameter carrying construct
// signatures. A class value is not an object type — its statics and its
// constructor come off the symbol, not out of a member table — so the
// structural inference walk skipped it and every such type parameter stayed at
// its constraint or at `unknown`.
//
// This is the shape every DI container and test factory is written in
// (`ClassConstructor<T>`, Nest's `Type<T>`, `new (...args: any[]) => T`), so
// each miss then reported TS2339 for every property read off the result.
interface Ctor<T = any> extends Function {
  new (...args: any[]): T;
}
class Base {
  b(): number {
    return 1;
  }
}
class Sub extends Base {
  s(): string {
    return "s";
  }
}

// Constrained: the constraint must not win over the argument.
declare function create<T extends Base>(C: Ctor<T>): T;
export const a: string = create(Sub).s();

// Unconstrained: `unknown` was the old answer.
declare function get<T>(C: Ctor<T>): T;
export const b: string = get(Sub).s();

// A second parameter DEFAULTED from the first — the `getMock<T, R = Mocked<T>>`
// shape; `R` is only right if `T` was.
type Wrap<T> = { inner: T };
declare function getWrapped<T, R = Wrap<T>>(C: Ctor<T>): R;
export const c: string = getWrapped(Sub).inner.s();

// A bare construct-signature type, with no `Function` heritage to hide behind.
declare function make<T>(C: new (...args: any[]) => T): T;
export const d: string = make(Sub).s();

// An abstract construct signature takes an abstract class value the same way.
abstract class Abs {
  abstract z(): number;
}
declare function forAbstract<T>(C: abstract new (...args: any[]) => T): T;
export const e: number = forAbstract(Abs).z();

// A generic class instantiates at `any` per parameter (tsc's `getInstanceType`),
// so its members are readable and nothing is narrowed by the inference.
class BoxOf<T> {
  constructor(public value: T) {}
}
export const f = get(BoxOf).value;

// The inference is real, not `any`: a wrong annotation is still caught, and a
// property on neither the class nor its base is still TS2339.
export const wrong: number = create(Sub).s();
export const missing = get(Sub).nope;
