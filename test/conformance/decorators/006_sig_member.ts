// Member decorators: a method decorator that cannot resolve is TS1241, a
// property/accessor decorator is TS1240. Getters and setters use the method
// code. Well-typed and `any` decorators are accepted.
declare const okM: (value: Function, ctx: ClassMethodDecoratorContext) => void;
declare const okF: (value: undefined, ctx: ClassFieldDecoratorContext) => void;
declare const okA: (value: unknown, ctx: ClassAccessorDecoratorContext) => void;
declare const bad: (value: string, ctx: number) => void;
declare const anyDeco: any;

class D {
  @okM @anyDeco method() {}
  @bad badM() {}
  @okF @anyDeco field = 1;
  @bad badF = 2;
  @okA accessor acc = 3;
  @bad accessor badAcc = 4;
  @bad get g() { return 1; }
  @bad set s(v: number) {}
  @okM static sm() {}
}
