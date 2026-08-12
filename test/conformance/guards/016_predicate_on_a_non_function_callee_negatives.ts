// The negatives for `015`: resolving the callee to a signature must not invent
// narrowing where the chosen overload has nothing to say.

declare function want(s: string): void;
declare const maybe: string | undefined;

// The overload the arguments pick carries no predicate, so nothing narrows.
declare function pick(v: string, m: string): asserts v is string;
declare function pick(v: number, m: string): void;
export function chosenOverloadHasNoPredicate() {
  pick(1, "m");
  want(maybe); // TS2345: still `string | undefined`
}

// A predicate is not an assertion: a plain `v is T` used as a STATEMENT
// narrows nothing (tsc requires `asserts`).
declare const isString: { (v: unknown): v is string };
export function predicateAsStatementDoesNotNarrow() {
  isString(maybe);
  want(maybe); // TS2345
}

// The subject must be the argument in the predicate's own position.
declare const assertSecondArg: { (tag: string, v: any): asserts v };
export function wrongPositionDoesNotNarrow() {
  assertSecondArg("tag", 1);
  want(maybe); // TS2345
}

// A callee with no call signature at all is not a guard (and not callable).
declare const notCallable: { p: number };
export function notCallableIsNotAGuard() {
  want(maybe); // TS2345
  return notCallable.p;
}
