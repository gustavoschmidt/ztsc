// A namespace whose body declares only types emits no runtime object, so tsc
// gives it `NamespaceModule` — a symbol with an EMPTY excludes mask. It merges
// with a `var`/`const` of the same name in either declaration order.
// `@types/node` relies on this six times over (`namespace webcrypto {…}` next
// to `const webcrypto`, `namespace strict {…}` next to `const strict`,
// `namespace signals {}` next to `const signals`, `namespace console {…}` next
// to `var console` inside a `global` block).
namespace strict {
  export type A = number;
}
declare const strict: {
  a: strict.A;
};

declare const web: web.C;
namespace web {
  export interface C {
    c: number;
  }
}

namespace empty {}
declare const empty: number;

// The same merge, performed inside a `global { … }` block of an ambient module.
declare module "g" {
  global {
    namespace mycon {
      interface Opts {
        colored: boolean;
      }
    }
    var mycon: {
      opts: mycon.Opts;
    };
  }
  export {};
}

const n1: number = strict.a;
const n2: number = web.c;
const n3: number = empty;
const n4: boolean = mycon.opts.colored;
const bad: string = mycon.opts.colored;
const bad2: string = web.c;
