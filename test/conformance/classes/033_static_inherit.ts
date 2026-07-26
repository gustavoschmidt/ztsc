// Static members are inherited: `typeof Derived` includes the base class's
// statics (own statics win over inherited on name clash).
//
// Note the shadowing on line 15 is *incompatible* (number vs string), which tsc
// reports as TS2417 on the `Derived` declaration — the static sides of a class
// and its base are related just like the instance sides. ztsc does not
// implement that check; the under-report is registered in
// `test/conformance/DEFERRED`.
class Base {
  static make(): number { return 1; }
  static shared(): string { return "base"; }
}
class Mid extends Base {}
class Derived extends Mid {
  static shared(): number { return 2; } // own static shadows Base.shared
}

// Inherited through two levels.
const a: number = Derived.make();
// Own static wins over the inherited one.
const b: number = Derived.shared();

// Negative controls: a genuinely-absent static still errors; and the base's
// static return type is enforced.
const bad: string = Base.make();
Derived.absentStatic();
