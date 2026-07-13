// An abstract class cannot be instantiated with `new` (TS2511), but can
// be used as a type.
abstract class A {
  abstract foo(): number;
}
declare const a: A;
const n: number = a.foo();
const bad = new A();
