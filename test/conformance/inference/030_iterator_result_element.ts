// Array.from over a real lib iterator (Map/Set values) recovers the element
// type through `next(): IteratorResult<T, TReturn>`, whose return is the union
// alias `IteratorYieldResult<T> | IteratorReturnResult<TReturn>`. Union members
// pair by identity during inference, so `T` is bound from the yield-result arm
// instead of collapsing the element to `unknown`.
declare const m: Map<number, { ts: Date }>;
const a = Array.from(m.values());
const a0: Date = a[0].ts; // element is { ts: Date }
for (const v of m.values()) {
  const t: Date = v.ts; // for-of element type
  void t;
}
const c = [...m.values()];
const c0: Date = c[0].ts; // spread element type
declare const s: Set<{ x: number }>;
const b = Array.from(s);
const b0: number = b[0].x;
void a0;
void c0;
void b0;
// Negative control: the element is concretely `{ ts: Date }` (so `.ts` is
// `Date`), not `unknown`/`any` — a wrong annotation must error.
const bad: string = a[0].ts; // TS2322
void bad;
