// `x instanceof C` where the constructor `C` is an intersection of class
// values (`typeof A & typeof B`) — the shape a `declare module` augmentation
// that merges a class declaration produces (`typeof Polygon & typeof Polygon`),
// and the shape a mixin produces. The instance type is the intersection of
// each member's instance type (`A & B`); without unwrapping the intersection
// the guard fell through to the constructor-object path, found no usable
// prototype, and left `x` at its declared union (dropping the narrowing).
declare class A { a: number; }
declare class B { b: number; }
declare const Ctor: typeof A & typeof B;

function f(x: A | { c: number }): void {
  if (x instanceof Ctor) {
    const a: number = x.a;
    const b: number = x.b;
    const c: number = x.c;
  }
}
