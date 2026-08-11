// TS2565, the read-side half of `strictPropertyInitialization`: inside the
// constructor of the class that declares it, a `this.x` READ reached on a path
// that has not written `x` yet is "used before being assigned". tsc's
// `getFlowTypeOfAccessExpression` sets `assumeUninitialized` for exactly that
// shape — a property declaration with no `!` and no initializer, accessed
// through `this`, whose control-flow container is the constructor of the
// declaring class — and reports on the property NAME.
//
// A definite assignment target is not a read (`this.x = v` is silent), but the
// read a COMPOUND assignment performs is (`this.x += v`, `this.x++`). A read
// inside a nested function is in a different control-flow container, and a
// property declared in a BASE class is not this constructor's business.

export class ReadsBeforeWrite {
  a: string;
  b: string;
  constructor() {
    this.b = this.a;
    this.a = "x";
  }
}

export class ReadsAndNeverWrites {
  a: string;
  constructor() {
    const local = this.a;
    void local;
  }
}

export class ReadsAfterWrite {
  a: string;
  constructor() {
    this.a = "x";
    const local = this.a;
    void local;
  }
}

export class ReadsOnOnePath {
  a: string;
  constructor(cond: boolean) {
    if (cond) {
      this.a = "x";
    }
    const local = this.a;
    void local;
  }
}

export class ReadsInAGuard {
  a: string;
  constructor() {
    if (this.a === undefined) {
      this.a = "x";
    }
  }
}

export class CompoundReads {
  a: string;
  n: number;
  constructor() {
    this.a += "x";
    this.n++;
  }
}

export class ReadsThroughACall {
  a: string;
  constructor() {
    accept(this.a);
    this.a = "x";
  }
}

export class ReadsInNestedArrow {
  a: string;
  constructor() {
    const get = () => this.a;
    this.a = get();
  }
}

export class NestedTargetIsStillARead {
  a: { p: string };
  constructor() {
    this.a.p = "x";
    this.a = { p: "y" };
  }
}

export class OptionalTypeIsSilent {
  a: string | undefined;
  b?: string;
  constructor() {
    const x = this.a;
    const y = this.b;
    void x;
    void y;
  }
}

export class DefiniteIsSilent {
  a!: string;
  b = "";
  constructor() {
    const x = this.a;
    const y = this.b;
    void x;
    void y;
  }
}

export class BaseDeclares {
  a: string;
  constructor() {
    this.a = "x";
  }
}
export class DerivedReadsBase extends BaseDeclares {
  constructor() {
    super();
    const x = this.a;
    void x;
  }
}

// Outside a constructor there is no check at all.
export class MethodReads {
  a: string;
  constructor() {
    this.a = "x";
  }
  read() {
    return this.a;
  }
}

declare function accept(v: unknown): void;
