// tsc's `isEnumTypeRelatedTo`: two DIFFERENT enum declarations relate when
// they share a NAME and every member of the source has a same-named member of
// the same value in the target. It is the one structural rule in an otherwise
// nominal type, and real programs lean on it — a package publishes an enum,
// an application redeclares it, and the two must interoperate.
//
// immich does exactly that: `src/dtos/env.dto.ts` re-writes
// `@immich/sql-tools`' `DatabaseSslMode` under a `// TODO import from
// sql-tools` note, and zod's `$InferEnumOutput<T> = T[keyof T]` hands the
// redeclared members into a parameter typed by the published one
// (`config.repository.ts:233`).
namespace A {
  export enum E {
    X = 'xv',
    Y = 'yv',
  }
}

namespace B {
  export enum E {
    X = 'xv',
    Y = 'yv',
    Z = 'zv',
  }
}

// A member of one reaches the whole other enum…
declare const ax: A.E.X;
export const b1: B.E = ax;

// …and the matching member of it.
export const b2: B.E.X = ax;

// …but not a different member.
export const b3: B.E.Y = ax;

// The whole enum relates to the whole enum, source-members-first: `A.E`'s two
// members are both in `B.E`, so `A.E -> B.E` holds and `B.E -> A.E` does not
// (`Z` is missing).
declare const ae: A.E;
declare const be: B.E;
export const b4: B.E = ae;
export const b5: A.E = be;

// A DIFFERENT name never relates, however identical the members.
namespace C {
  export enum F {
    X = 'xv',
    Y = 'yv',
  }
}
declare const cx: C.F.X;
export const b6: A.E = cx;

// Neither does a same-named enum whose member VALUE differs.
namespace D {
  export enum E {
    X = 'other',
    Y = 'yv',
  }
}
declare const dx: D.E.X;
export const b7: A.E = dx;

// A numeric redeclaration relates the same way.
namespace N1 {
  export enum G {
    P = 1,
    Q = 2,
  }
}
namespace N2 {
  export enum G {
    P = 1,
    Q = 2,
  }
}
declare const np: N1.G.P;
export const b8: N2.G = np;

// A `const enum` is out of tsc's `SymbolFlags.RegularEnum` test.
namespace K1 {
  export const enum H {
    P = 'pv',
  }
}
namespace K2 {
  export enum H {
    P = 'pv',
  }
}
declare const kp: K1.H.P;
export const b9: K2.H = kp;
