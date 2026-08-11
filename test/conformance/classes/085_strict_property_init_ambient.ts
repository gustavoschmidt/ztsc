// `strictPropertyInitialization` is skipped entirely inside an AMBIENT class —
// tsc's `checkPropertyInitialization` returns early on `node.flags &
// NodeFlags.Ambient`, which covers a `declare class`, a class in a `declare
// namespace` body, and every class in a `.d.ts`. There is no constructor body
// to analyze there, so the check would report on every property.
//
// The non-ambient classes in the same file still report, so this case also
// pins that `declare` does not leak out of its declaration.

export declare class Ambient {
  a: string;
  b: number;
  constructor(a: string);
}

export declare abstract class AmbientAbstract {
  a: string;
}

export declare namespace NS {
  class InNamespace {
    a: string;
  }
}

declare global {
  class InGlobal {
    a: string;
  }
}

// Not ambient: reported.
export class Real {
  a: string;
}

export namespace Instantiated {
  export class Nested {
    a: string;
  }
}
