// The legacy dialect contextually types a decorator with the
// `(target, propertyKey, descriptor)` tuple its runtime passes, so a
// three-parameter decorator on a member of the method family has no
// implicit-any parameters either.
class C {
  @((target, key, desc) => {
    const t: C = target;
    const k: "m" = key;
    const d: TypedPropertyDescriptor<(x: number) => void> = desc;
  })
  m(x: number) {}

  @((target, key) => {
    const t: typeof C = target;
    const k: "f" = key;
  })
  static f = 1;

  @((target, key, desc) => {
    const d: TypedPropertyDescriptor<number> = desc;
  })
  get p() {
    return 1;
  }
}

// A shape the runtime cannot fill is not used AT ALL (tsc's `isAritySmaller`):
// a plain property decorator is invoked with two arguments, so a
// three-parameter one keeps the arity failure AND reports every parameter as
// implicitly `any` — suppressing those would trade excess keys for missing
// ones.
class D {
  @((target, key, desc) => {})
  p = 1;
}
