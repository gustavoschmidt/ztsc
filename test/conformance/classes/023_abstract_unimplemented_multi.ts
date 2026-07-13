// Two or more unimplemented abstract members collapse to the aggregate
// TS2654 rather than one TS2515 each.
abstract class A {
  abstract foo(): number;
  abstract bar(): string;
  abstract baz: boolean;
}
class B extends A {}
