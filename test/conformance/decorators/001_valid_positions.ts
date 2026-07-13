// TC39 standard decorators (no experimentalDecorators). A decorator is a
// left-hand-side expression that is name-resolved and type-checked. An
// `any`-typed or a validly-typed decorator is accepted with no error at any
// position: class, method, field, static field, accessor, getter, and a
// stacked pair. This case must be diagnostic-free.
type ClassDeco = (value: any, ctx: any) => any;
declare const anyDeco: any;
declare const typedDeco: ClassDeco;

@anyDeco
class A {}

@typedDeco
class B {}

@anyDeco @typedDeco
class C {}

class D {
  @anyDeco field = 1;
  @anyDeco method() {}
  @anyDeco static staticField = 2;
  @anyDeco accessor acc = 3;
  @anyDeco get getter() {
    return 4;
  }
}
