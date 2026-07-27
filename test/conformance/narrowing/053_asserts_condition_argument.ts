// `asserts cond` (no `is T`) narrows by its ARGUMENT AS A CONDITION, not by
// requiring the tracked reference to be the argument. tsc's
// `narrowTypeByAssertion` hands the argument expression to the condition
// narrower with `assumeTrue`; ztsc only ever caught the degenerate
// `invariant(x)` shape.
declare function invariant(cond: unknown, msg?: string): asserts cond;

export function equality(x: string | null) {
  invariant(x !== null);
  return x.length;
}

export function typeofNarrow(v: unknown) {
  invariant(typeof v === "string");
  return v.length;
}

export function truthy(x: string | null) {
  invariant(x);
  return x.length;
}

export function discriminant(s: { k: "a"; a: number } | { k: "b"; b: string }) {
  invariant(s.k === "a");
  return s.a;
}

export function optionalChain(o: { p?: { q: number } } | null) {
  invariant(o?.p);
  return o.p.q;
}

// Negative: the assertion says nothing about a DIFFERENT reference.
export function otherRef(x: string | null, y: string | null) {
  invariant(x !== null);
  return y.length;
}

// Negative: nothing is narrowed BEFORE the call.
export function beforeCall(x: string | null) {
  const before = x.length;
  invariant(x !== null);
  return before;
}

// `asserts x is T` still names its subject positionally.
declare function assertString(v: unknown): asserts v is string;

export function isForm(v: unknown) {
  assertString(v);
  return v.length;
}
