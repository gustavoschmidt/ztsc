// A concrete class implementing all inherited abstract members (method,
// property, accessor) checks clean and is instantiable.
abstract class A {
  abstract foo(): number;
  abstract x: string;
  abstract get y(): number;
}
class B extends A {
  foo(): number { return 1; }
  x = "ok";
  get y() { return 2; }
}
const b = new B();
const n: number = b.foo();
