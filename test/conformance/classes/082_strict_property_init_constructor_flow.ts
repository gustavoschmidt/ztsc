// `strictPropertyInitialization` (TS2564), flow side: "definitely assigned in
// the constructor" is tsc's ordinary control-flow analysis run over the
// constructor's RETURN join — the binder's `returnFlowNode`, which unions the
// fall-off-the-end edge with every `return` — asking whether the reference
// `this.x` can still be `undefined` there.
//
// So every path has to write it: a branch that does not, an early `return`, a
// loop that may not run, or a `catch` that skips the write all leave the
// report standing, while a `throw` (or a `never`-returning call) removes the
// path entirely.

export class NoCtor {
  a: string;
}

export class Partial {
  assigned: string;
  missed: string;
  constructor() {
    this.assigned = "x";
  }
}

export class Branches {
  onlyThen: string;
  bothArms: string;
  constructor(cond: boolean) {
    if (cond) {
      this.onlyThen = "x";
      this.bothArms = "x";
    } else {
      this.bothArms = "y";
    }
  }
}

export class EarlyReturn {
  a: string;
  constructor(cond: boolean) {
    if (cond) {
      return;
    }
    this.a = "y";
  }
}

export class ReturnsOnEveryPath {
  a: string;
  constructor(cond: boolean) {
    if (cond) {
      this.a = "x";
      return;
    }
    this.a = "y";
  }
}

export class ThrowsInstead {
  a: string;
  constructor() {
    throw new Error("nope");
  }
}

export class ThrowsOnTheOtherArm {
  a: string;
  constructor(cond: boolean) {
    if (cond) {
      this.a = "x";
    } else {
      throw new Error("nope");
    }
  }
}

declare function fail(msg: string): never;

export class NeverCall {
  a: string;
  constructor() {
    fail("nope");
  }
}

export class Loops {
  maybe: string;
  forOfMaybe: string;
  always: string;
  alwaysDo: string;
  alwaysForever: string;
  constructor(n: number) {
    for (let i = 0; i < n; i++) {
      this.maybe = "x";
    }
    for (const s of ["a"]) {
      this.forOfMaybe = s;
    }
    while (true) {
      this.always = "x";
      break;
    }
    do {
      this.alwaysDo = "x";
    } while (false);
    for (;;) {
      this.alwaysForever = "x";
      break;
    }
  }
}

export class TruthyOne {
  a: string;
  constructor() {
    // `while (1)` is not `while (true)`: only the literal keyword makes the
    // fall-out edge unreachable, in tsc as here.
    while (1) {
      this.a = "x";
      break;
    }
  }
}

export class Switches {
  covered: string;
  uncovered: string;
  constructor(k: "a" | "b") {
    switch (k) {
      case "a":
        this.covered = "1";
        break;
      default:
        this.covered = "2";
    }
    switch (k) {
      case "a":
        this.uncovered = "1";
        break;
    }
  }
}

export class TryCatch {
  a: string;
  constructor() {
    try {
      this.a = "x";
    } catch {}
  }
}

export class TryCatchRethrows {
  a: string;
  constructor() {
    try {
      this.a = "x";
    } catch (e) {
      throw e;
    }
  }
}

export class ViaMethod {
  a: string;
  constructor() {
    this.setup();
  }
  setup() {
    this.a = "x";
  }
}

export class ViaAlias {
  a: string;
  constructor() {
    const self = this;
    self.a = "x";
  }
}

export class ViaCallback {
  a: string;
  constructor() {
    const later = () => {
      this.a = "x";
    };
    later();
  }
}

export class CompoundOnly {
  a: string;
  n: number;
  constructor() {
    this.a += "x";
    this.n++;
  }
}

// A base class's constructor initializes nothing of the derived class.
export class Base {
  b: string;
  constructor() {
    this.b = "x";
  }
}
export class Derived extends Base {
  d: string;
  constructor() {
    super();
  }
}
