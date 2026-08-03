// A contextual type with SEVERAL call signatures still yields a contextual
// signature. tsc's `getContextualCallSignature` takes the sole applicable one
// or, failing that, COMBINES them
// (`getIntersectedSignatures` -> `combineSignaturesOfIntersectionMembers`):
// parameter types union position-wise, return types intersect.
//
// ztsc did that for an INTERSECTION of callables but not for an overload set,
// which is the other way a type ends up with several signatures — and the way
// it happens in practice, because `lib.dom` and `@types/node` each declare
// `fetch` and each declare `Console.trace`. An object literal written
// `as Console`, or an arrow assigned to `globalThis.fetch`, therefore got no
// contextual parameter types at all and reported TS7006 on every one.

interface Ov {
  m(a: string): void;
  m(a: number, b?: string): void;
}

// Overloaded member of an object-literal target.
const viaMember: Ov = { m: (a) => a };

// Overloaded call signatures on the contextual type itself.
type F = { (a: string): void; (a: number, b?: string): void };
const viaCallSigs: F = (a) => {
  const t: string | number = a;
  return t;
};

// A REST parameter is read through, as `tryGetTypeAtPosition` does — the
// `Console.trace` shape, where one overload is all-rest and the other has a
// leading optional.
interface Logger {
  log(...data: string[]): void;
  log(message?: string, ...rest: string[]): void;
}
const viaRest: Logger = {
  log: (message) => {
    const m: string | undefined = message;
    return m;
  },
};

// The sole-signature path is unchanged.
interface One {
  (a: string): number;
  displayName?: string;
}
const sole: One = (a) => a.length;

export { viaMember, viaCallSigs, viaRest, sole };
