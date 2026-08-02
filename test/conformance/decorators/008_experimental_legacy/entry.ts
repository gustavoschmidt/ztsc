// `experimentalDecorators` selects the LEGACY decorator dialect. Two things
// change relative to the standard (TC39) decorators the rest of this directory
// exercises, and both are covered here:
//
//   1. parameter decorators are grammatical, so none of these is TS1206 —
//      007_param_decorator is the same shapes with the flag off, and every
//      one of them is an error there;
//   2. a legacy decorator is invoked as `(target, key, descriptorOrIndex)`,
//      not as the standard `(value, context)`, so a decorator written to the
//      legacy shape must not draw TS1238/TS1240/TS1241.
//
// Every decorator below is written with a legacy signature on purpose: under
// the standard dialect each of them fails the context-parameter check.
declare function ClassDeco(target: Function): void;
declare function PropDeco(target: object, key: string): void;
declare function MethodDeco(target: object, key: string, desc: PropertyDescriptor): void;
declare function ParamDeco(target: object, key: string | undefined, index: number): void;
declare function Factory(opts: { name: string }): (target: object, key: string) => void;

@ClassDeco
class Service {
  @PropDeco field = 1;
  @Factory({ name: "x" }) labeled = "y";

  constructor(@ParamDeco private dep: string, @ParamDeco other: number) {
    this.labeled += other;
  }

  @MethodDeco
  run(@ParamDeco a: number, @ParamDeco b: string): string {
    return this.dep + a + b;
  }

  @MethodDeco
  get value(): number {
    return this.field;
  }
}

export { Service };
