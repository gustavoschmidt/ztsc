// `super(…)` is not a call on a value. tsc's `resolveCallExpression`
// special-cases it and resolves against the containing class's BASE
// constructor type — `getInstantiatedConstructorsForTypeArguments(superType,
// baseTypeNode.typeArguments)` — so the arguments are checked against the base
// constructor's parameters, with their contextual types.
//
// ztsc types the `super` KEYWORD as `any`, which made every `super(…)` an
// untyped call: its arguments were checked with no contextual type at all.
// social-app's `class BskyAppAgent extends AtpAgent { constructor({service}) {
// super({ service, async fetch(...args) {…} }) } }` lost the contextual
// `typeof globalThis.fetch` on the `fetch` method, so its rest parameter was an
// implicit any (TS7006).
type Handler = (input: string, init?: { n: number }) => Promise<string>;

type Opts = {
  service: string;
  fetch?: Handler;
};
declare class Session {
  sessionManager: number;
}

declare class Base {
  constructor(options: Opts | Session);
}

declare const realFetch: Handler;

class D1 extends Base {
  constructor({ service }: { service: string }) {
    super({
      service,
      // Contextually typed by `Opts['fetch']`, picked out of the union.
      async fetch(...args) {
        const first: string = args[0];
        return realFetch(...args) + first;
      },
    });
  }
}

// The argument is checked, not waved through.
class D2 extends Base {
  constructor() {
    super({ service: 42 });
  }
}
class D3 extends Base {
  constructor() {
    super();
  }
}

// A generic base: the heritage arguments reach the constructor's parameters.
declare class GBase<T> {
  constructor(value: T, sink: (v: T) => void);
}
class D4 extends GBase<number> {
  constructor() {
    super(1, v => {
      const n: number = v;
      return n;
    });
  }
}
class D5 extends GBase<number> {
  constructor() {
    super('nope', () => {});
  }
}

// A base with no declared constructor keeps the implicit zero-arg one.
declare class Plain {}
class D6 extends Plain {
  constructor() {
    super();
  }
}

export { D1, D2, D3, D4, D5, D6 };
