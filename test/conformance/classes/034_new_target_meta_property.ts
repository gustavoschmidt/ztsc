// `new.target` is a meta-property expression, not out-of-subset syntax.
// ztsc parsed it into an `unsupported` node and reported the subset
// boundary, which also swallowed the surrounding expression.
//
// Its type is a documented under-report: tsc gives the enclosing
// constructor's own type (the class's static side in a constructor,
// `typeof f` in a plain function); ztsc gives `any`. So this case asserts
// the parse and the surrounding checks, not the meta-property's members.
class Base {
  kind: string;
  constructor() {
    const t = new.target;
    this.kind = t === undefined ? "plain" : "new";
  }
}

class Derived extends Base {
  constructor() {
    super();
    const n: unknown = new.target;
    void n;
  }
}

function asCtor(this: unknown) {
  if (new.target === undefined) {
    return 0;
  }
  return 1;
}

// The meta-property is an ordinary operand: it chains and composes.
class Chained {
  constructor() {
    const guard = new.target ? 1 : 2;
    const viaCall = [new.target].length;
    const num: number = guard + viaCall;
    void num;
  }
}

// `new X()` right next to it still parses as a construction.
class Holder {
  inner: Base;
  constructor() {
    this.inner = new Base();
    void new.target;
  }
}

const a = new Base();
const b = new Derived();
const c = new Chained();
const d = new Holder();
const e: number = asCtor();
