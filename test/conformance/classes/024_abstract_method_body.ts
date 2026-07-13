// An abstract method cannot have an implementation (TS1245); its declared
// return type still demands a value (TS2355).
abstract class A {
  abstract foo(): number {}
}
