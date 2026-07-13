// A decorator factory `@f(args)` has its callee and arguments type-checked
// like any call. A valid factory call is clean; a bad argument is TS2345; an
// undefined factory callee is TS2304.
declare function make(n: number): (value: any, ctx: any) => void;

@make(1)
class A {}

class B {
  @make("bad") method() {}
}

@missingFactory()
class C {}
