// A fresh literal candidate is widened only when the inference was made at the
// TOP LEVEL of the parameter type it came from (tsc's
// `InferenceInfo.topLevel`), and a return-context SEED must reach a parameter
// that has a default — the seed is never the answer, so a default cannot be
// "overridden" by it.
//
// `fromEntries<T = any>(e: Iterable<readonly [PropertyKey, T]>): { [k: string]: T }`
// needs both: the seed gives the callback's array literal a contextual type so
// its `true` survives, and the top-level rule keeps `T` from widening it back
// to `boolean`.

declare const els: { id: string }[];

declare function fromEntries<T = any>(
  entries: Iterable<readonly [PropertyKey, T]>,
): { [k: string]: T };
declare function noDefault<T>(
  entries: Iterable<readonly [PropertyKey, T]>,
): { [k: string]: T };

export const a: { [id: string]: true } = fromEntries(els.map((el) => [el.id, true]));
export const b: Readonly<{ [id: string]: true }> = fromEntries(
  els.map((el) => [el.id, true]),
);
export const c: { [id: string]: true } = noDefault(els.map((el) => [el.id, true]));

// A buried parameter with an explicit `as const` argument was already fine.
export const d: { [id: string]: true } = fromEntries(
  els.map((el) => [el.id, true] as const),
);
