// A concrete class must implement a single inherited abstract member
// (TS2515).
abstract class A {
  abstract foo(): number;
}
class B extends A {}
