// Polymorphic `this` return: a method declared `(): this` returns the
// receiver's (possibly subclass) type, so a fluent chain preserves the
// concrete subclass. `b.base().extra()` must resolve `extra` on B — it would
// not if `base()` returned the declared class A.
class A {
  base(): this {
    return this;
  }
}
class B extends A {
  extra(): number {
    return 1;
  }
}
const b = new B();
const n: number = b.base().extra();
// Chaining stays on B across several `this` returns.
const n2: number = b.base().base().extra();
// On an A receiver, `base()` is an A — no `extra`.
const a = new A();
a.base().extra();
