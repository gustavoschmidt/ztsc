// tsc reads a predicate off the RESOLVED SIGNATURE of a call
// (`getEffectsSignature`), not off the callee's type — so a predicate declared
// on an OVERLOAD SET or on an interface/object-literal CALL SIGNATURE narrows
// exactly like one on a plain `declare function`. `@types/invariant` is the
// second shape (a `let` of an interface with two call signatures) and it is
// outline's most-used assertion; a `.function`-only test made every one of
// them invisible.

declare function want(s: string): void;
declare const maybe: string | undefined;

// The `@types/invariant` shape verbatim: an interface with two call
// signatures, the `asserts` one second, reached through `declare let`.
declare namespace inv {
  interface InvariantStatic {
    (testValue: false, format: string, ...extra: any[]): never;
    (testValue: any, format: string, ...extra: any[]): asserts testValue;
  }
}
declare let invariant: inv.InvariantStatic;

export function viaInterfaceOverloads() {
  invariant(maybe, "msg");
  want(maybe);
}

// A dotted path as the assertion subject.
declare const env: { A?: string };
export function viaDottedSubject() {
  invariant(env.A, "msg");
  want(env.A);
}

// A single call signature on an interface.
interface Single {
  (testValue: any, format: string): asserts testValue;
}
declare const single: Single;
export function viaSingleCallSignature() {
  single(maybe, "msg");
  want(maybe);
}

// A call signature on an object type literal.
declare const objLit: { (testValue: any, format: string): asserts testValue };
export function viaObjectTypeLiteral() {
  objLit(maybe, "msg");
  want(maybe);
}

// An overloaded `declare function`, `asserts` on either declaration: the
// overload the ARGUMENTS pick is the one that speaks.
declare function assertFirst(v: any, m: string): asserts v;
declare function assertFirst(v: false, m: string): never;
export function viaOverloadFirst() {
  assertFirst(maybe, "m");
  want(maybe);
}

declare function assertSecond(v: false, m: string): never;
declare function assertSecond(v: any, m: string): asserts v;
export function viaOverloadSecond() {
  assertSecond(maybe, "m");
  want(maybe);
}

// A plain `x is T` predicate on the same shapes.
declare const isString: { (v: unknown): v is string };
declare const unk: unknown;
export function plainPredicateOnCallSignature() {
  if (isString(unk)) {
    want(unk);
  }
}

interface IsStr {
  (v: unknown): v is string;
  (v: unknown, strict: boolean): v is string;
}
declare const isStr2: IsStr;
export function plainPredicateOnOverloadSet() {
  if (isStr2(unk)) {
    want(unk);
  }
}
