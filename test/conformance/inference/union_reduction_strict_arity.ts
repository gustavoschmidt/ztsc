// Union reduction runs under tsc's `strictSubtypeRelation`, whose signature
// comparison uses `SignatureCheckMode.StrictArity` — parameter COUNT, not
// minimum count. So `(b?: string) => void` is NOT a subtype of `() => void`
// even though the two are mutually assignable, and `??` keeps the arm that
// takes an argument. Reducing the other way reported a false TS2554 on the
// call below (`unionReductionMutualSubtypes`).

interface ReturnVal {
  something(): void;
}

declare const val: ReturnVal;

export function run(options: { something?(b?: string): void }) {
  const something = options.something ?? val.something;
  something("");
}

export function run2(options: { something?(b?: string): void }) {
  const something = val.something ?? options.something;
  something("");
}

// NEGATIVE (the reduction still collapses a genuine subtype pair) -------------

declare const wide: (a: string) => void;
declare const narrow: (a: "x") => void;
declare const cond: boolean;

export const picked = cond ? wide : narrow;
export const call = picked("anything");
