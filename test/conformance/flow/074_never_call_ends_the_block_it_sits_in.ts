// tsc's `getTypeAtFlowCall` answers `unreachableNeverType` for EVERY query
// crossing a call statement whose resolved signature returns `never`, not only
// for a definite-assignment one. A guard block that ends in such a call
// therefore contributes nothing to the join after it — which is how koa's
// `ctx.throw(...)` (declared `never`) ends an `if (!file)` block.

declare const ctx: { throw(e: string): never };
declare const file: { size: number } | undefined;

export function throwHelperEndsTheBlock() {
  if (!file) {
    ctx.throw("no file");
  }
  return file.size;
}

declare function fail(m: string): never;

export function freeFunctionForm(x: string | undefined) {
  if (!x) {
    fail("no x");
  }
  return x.length;
}

// The reads AFTER an unconditional `never` call are in dead code, where tsc
// hands back the DECLARED type rather than `never` — including reads inside a
// closure defined there, whose body can still be invoked.
export function deadCodeReadsTheDeclaredType(x: string | undefined) {
  fail("always");
  const f = () => x;
  return f();
}

// Negative control: a call that does not return `never` ends nothing.
declare function noop(m: string): void;

export function plainCallEndsNothing() {
  if (!file) {
    noop("no file");
  }
  return file.size; // TS18048
}

// Negative control: the `never` overload of a set the arguments do NOT pick
// says nothing either. `@types/invariant`'s first overload returns `never`,
// and reading it off the set (instead of off the resolved signature) cancelled
// every assertion the second one makes.
declare function invariant(v: false, m: string): never;
declare function invariant(v: any, m: string): asserts v;

export function assertionOverloadWins(x: string | undefined) {
  invariant(x, "x is required");
  return x.length;
}
