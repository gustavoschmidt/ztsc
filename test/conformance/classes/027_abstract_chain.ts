// An abstract class may extend another without implementing its abstract
// members; only the first concrete descendant must (TS2515).
abstract class A {
  abstract foo(): number;
}
abstract class B extends A {}
class C extends B {}
