// The CONSTRUCTOR side of a class (`typeof C`) has the apparent members of the
// global `Function` interface, exactly as a function expression does — plus the
// implicit `prototype`, which tsc synthesizes as the instance type with `any`
// for each type parameter (`getTypeOfPrototypeProperty`).
//
// `C.name` is the idiom every DI container / test factory / log line is built
// on, and a class-value arm that only looked at declared statics reported
// TS2339 for it on every class in the program.
class Plain {
  method(): void {}
}

export const n: string = Plain.name;
export const len: number = Plain.length;
export const proto: Plain = Plain.prototype;
export const str: string = Plain.toString();
// `prototype` is the INSTANCE type, so a name that is not an instance member
// is still TS2339 through it — it is not `Function.prototype`'s `any`.
export const protoMissing = Plain.prototype.nope;

// A declared static wins over the `Function` member of the same name.
class Shadow {
  static name = 42;
}
export const shadowed: number = Shadow.name;

// Inherited statics are still found before the `Function` fallback.
class Base {
  static shared(): number {
    return 1;
  }
}
class Derived extends Base {}
export const inherited: number = Derived.shared();
export const derivedName: string = Derived.name;

// A generic class's `prototype` is the instance type with `any` per parameter,
// so its members are readable and nothing narrows.
class Box<T> {
  constructor(public value: T) {}
}
export const boxProto = Box.prototype.value;
export const boxName: string = Box.name;

// A name that is on neither the statics nor `Function` is still TS2339.
export const missing = Plain.nope;
// And the `Function` members keep their real types.
export const wrongType: number = Plain.name;
