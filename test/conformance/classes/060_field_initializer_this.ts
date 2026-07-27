// `this` inside an UN-ANNOTATED class field's initializer.
//
// Such a field's type is inferred from its initializer, so the initializer is
// typed while the class's instance type is still being built. Walking the
// function body there resolved every `this.<member>` against the in-progress
// (therefore `any`) instance, and the memoized expression type then kept the
// later, correct pass from ever re-entering the body — so nothing inside it was
// checked against the real class. Every callback in such a body also lost its
// contextual type and its parameters went implicit-`any`.
declare function use(x: unknown): void;

class C {
  n = 1;
  label = "x";

  // Un-annotated: the type comes from the initializer.
  go = () => {
    const a: string = this.n;
    const b: number = this.label;
    // A callback argument is contextually typed by the method's parameter, so
    // `v` is `number` — not an implicit `any`.
    this.run((v) => use(v));
    this.run((v) => {
      const c: string = v;
      use(c);
    });
    // A member that does not exist is still an error.
    use(this.nope);
  };

  // Annotated: the type comes from the annotation, so the initializer was
  // already checked against the finished class. Must stay identical.
  ann: () => void = () => {
    const d: string = this.n;
    this.run((v) => use(v));
  };

  run(cb: (v: number) => void) {
    cb(this.n);
  }

  // `this` in a STATIC member is the class's constructor type, not the
  // instance — an instance member is not reachable through it.
  static s = 2;
  static goStatic = () => {
    const e: string = this.s;
    use(this.n);
  };
}

export { C };
