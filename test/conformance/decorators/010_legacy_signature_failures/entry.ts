// LEGACY (`experimentalDecorators`) decorators are resolved as ordinary calls
// against the argument tuple the runtime hands them — `[ctor]` for a class,
// `[target, key]` for a property, `[target, key, descriptor]` for a method or
// an `accessor` field — and a decorator no signature accepts draws TS1238
// (class), TS1240 (property) or TS1241 (method). 008 is the same dialect from
// the other side: legacy shapes that must stay silent.
//
// Two anchors of the shape are load-bearing and each has its own group below:
//
//   * WHICH argument the tuple carries — the instance type for an instance
//     member and the CONSTRUCTOR for a static one, the member name as a
//     string LITERAL, `TypedPropertyDescriptor<T>` over the member's own type
//     (the property type for an accessor, not its function type);
//   * WHERE the failure is blamed — an argument mismatch on the decorator's
//     expression, too FEW arguments on the whole decorator (`@` included),
//     too MANY back on the expression again, because every argument tsc
//     synthesizes points at that expression.
//
// A parameter typed by a literal rejects every argument, so each case below
// names the argument the tuple carried in its own message.

declare function Lit0(t: 1, k: unknown): void;
declare function Lit1(t: unknown, k: 1): void;
declare function Lit2(t: unknown, k: unknown, d: 1): void;
declare function LitClass(t: 1): void;

// --- which argument -------------------------------------------------------

@LitClass
class Target {
  // instance property: `[Target, "inst"]`
  @Lit0 inst!: string;
  @Lit1 named!: string;

  // static property: the tuple's target is `typeof Target`
  @Lit0 static stat: string = "";

  // method: `[Target, "run", TypedPropertyDescriptor<(x: number) => string>]`
  @Lit0 run(x: number): string {
    return String(x);
  }
  @Lit1 run2(): void {}
  @Lit2 run3(): void {}

  // accessors are METHOD decorators (TS1241), and their descriptor is over
  // the PROPERTY type — `number` here, not `() => number`. Only one of a
  // get/set PAIR may be decorated (TS1207), so the setter below has its own
  // name.
  @Lit2 get size(): number {
    return 0;
  }
  @Lit2 set width(v: number) {}

  // an `accessor` field is a PROPERTY decorator (TS1240) handed three
  // arguments
  @Lit2 accessor auto: string = "";
}

// A generic class contributes its own type parameters to the target.
class Boxed<T> {
  @Lit0 held!: T;
}

// --- arity ----------------------------------------------------------------

declare function TooFew(a: unknown): void;
declare function TooMany(a: unknown, b: unknown, c: unknown): void;
declare function AtLeast(a: unknown, b: unknown, c: unknown, ...r: unknown[]): void;
declare function Range(a: unknown, b: unknown, c: unknown, d?: unknown, e?: unknown): void;

class Arity {
  // 2 arguments, 1 parameter: too many, blamed on the expression
  @TooFew a!: string;
  // 2 arguments, 3 required: too few, blamed on the decorator
  @TooMany b!: string;
  @AtLeast c!: string;
  @Range d!: string;

  // a method is handed three arguments, but a signature of two parameters or
  // fewer is only offered two — so `TooMany` fits here and `TooFew` does not.
  @TooMany m(): void {}
  @TooFew m2(): void {}
}

// --- the shape this closed on outline -------------------------------------
// A property decorator declared against one model base (`@Field(target:
// Model, key)`) applied to a class that is NOT a `Model` — outline's sixty
// TS1240s, whose whole content is this one relation. What makes the two
// unrelated is a PROPERTY-held function (`store.add`, an arrow field rather
// than a method): its parameter is related strictly, so the verdict turns on
// the CONTRAVARIANT direction, where the wider class cannot stand in for the
// narrower one.

declare class Model {
  id: string;
  store: { add: (item: Model) => Model };
}
declare class Widened {
  id: string;
  extra: number;
  store: { add: (item: Widened) => Widened };
}
declare function Field(target: Model, key: string | symbol): void;

class Holder extends Widened {
  @Field name!: string;
}

export { Target, Boxed, Arity, Holder };
