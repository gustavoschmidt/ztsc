// `strictPropertyInitialization` negatives: the shapes of write that DO
// initialize the property, so no TS2564 follows.
//
// The interesting ones are the writes ztsc's narrowing does not track as
// references on its own: a destructuring-assignment element target, and the
// string-index spelling `this["x"]` (tsc's `getAccessedPropertyName` reads a
// string-literal index as a property name, so the two spellings denote the same
// reference).
//
// Two rows in the snapshot are deliberate, and both are about a *guard* rather
// than a write:
//
//   * `&&=` is the one logical assignment that does NOT initialize. All three
//     are `AssignmentKind.Definite` to tsc, but the branch that skips a `&&=`
//     is the FALSY one, and `string | undefined` narrowed to falsy still
//     contains `undefined` — so `c` is reported while `??=` and `||=` are not.
//   * a guard that removes `undefined` (`if (this.a === undefined) throw`)
//     initializes the property as far as the exit is concerned, but the guard's
//     own `this.a` is a read before any write, which is TS2565.

export class Plain {
  a: string;
  constructor() {
    this.a = "x";
  }
}

export class WrongTypeStillWrites {
  a: string;
  constructor(v: any) {
    // An `any` right-hand side, and a value that does not even fit: the write
    // is what counts, not what it wrote.
    this.a = v;
  }
}

export class StringIndex {
  a: string;
  constructor() {
    this["a"] = "x";
  }
}

export class DestructuredObject {
  a: string;
  b: string;
  constructor(o: { a: string; b: string }) {
    ({ a: this.a, b: this.b } = o);
  }
}

export class DestructuredWithDefault {
  a: string;
  constructor(o: { a?: string }) {
    ({ a: this.a = "d" } = o);
  }
}

export class DestructuredArray {
  a: string;
  b: string;
  constructor(arr: string[]) {
    [this.a, this.b] = [arr[0], arr[1]];
  }
}

export class LogicalAssignments {
  a: string;
  b: string;
  c: string;
  constructor() {
    this.a ??= "x";
    this.b ||= "y";
    this.c &&= "z";
  }
}

export class Chained {
  a: string;
  b: string;
  constructor() {
    this.a = this.b = "x";
  }
}

export class Ternary {
  a: string;
  constructor(cond: boolean) {
    cond ? (this.a = "x") : (this.a = "y");
  }
}

export class InsideExpression {
  a: string;
  constructor() {
    const o = { p: (this.a = "x") };
    void o;
  }
}

export class LabeledBlock {
  a: string;
  constructor() {
    outer: {
      this.a = "x";
      break outer;
    }
  }
}

export class ParameterProperties {
  a: string;
  constructor(
    public p: string,
    private readonly q: number,
  ) {
    this.a = p + q;
  }
}

export class Overloaded {
  a: string;
  constructor();
  constructor(x: number);
  constructor(x?: number) {
    this.a = String(x ?? 0);
  }
}

export class NarrowedByGuard {
  a: string;
  constructor() {
    if (this.a === undefined) {
      throw new Error("nope");
    }
  }
}

export class NarrowedThenAssigned {
  a: string;
  constructor(cond: boolean) {
    if (cond) {
      this.a = "x";
    }
    if (this.a === undefined) {
      this.a = "y";
    }
  }
}

export class TryFinally {
  a: string;
  constructor() {
    try {
      this.a = "x";
    } finally {
    }
  }
}

export class ImmediatelyInvoked {
  a: string;
  constructor() {
    (() => {
      this.a = "x";
    })();
  }
}
