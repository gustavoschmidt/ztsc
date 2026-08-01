// Reading a member of `never` is a TS2339 (094_negatives) — but tsc has TWO
// `never`s and only one of them is a type anyone may read. The other is
// `unreachableNeverType`, which the walk answers when it bottoms out in code
// no control path reaches, and `getFlowTypeOfReference` swaps it for the
// DECLARED type before it can reach a member access. Every read below is
// therefore silent, while the same shapes in 094_negatives all report.
declare function fail(msg: string): never;

// Dead after `return`: the reference is back at its declared type.
export function afterReturn(x: { a: string }) {
  return x.a;
  return x.a.length;
}

// Dead after `throw`.
export function afterThrow(x: { a: string }) {
  throw x;
  return x.a.length;
}

// Dead after a call whose signature returns `never`. Without that edge the
// discriminant is an exhausted union here — a readable `never`, which is
// exactly what 094_negatives asserts for the same shape minus the call.
export function afterNeverCall(x: { k: "a" } | { k: "b" }) {
  if (x.k === "a") return 1;
  if (x.k === "b") return 2;
  fail("unreachable");
  return x.k.length;
}

// `typeof v === "function"` keeps a CALLABLE object type: an interface with
// a call signature IS a function at runtime, so the true branch is the
// interface itself and not the empty set.
interface Callable {
  (n: number): string;
  tag: string;
}
export function callableGuard(v: Callable) {
  if (typeof v === "function") {
    return v.tag.length;
  }
  return 0;
}

// Same for a construct signature.
interface Ctor {
  new (n: number): { a: string };
  tag: string;
}
export function ctorGuard(v: Ctor) {
  if (typeof v === "function") {
    return v.tag.length;
  }
  return 0;
}
