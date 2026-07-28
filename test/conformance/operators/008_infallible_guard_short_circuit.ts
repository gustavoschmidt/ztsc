// A guard that cannot fail contributes nothing to the result type. tsc reads
// `getTypeFacts` off the left operand before building the union: `||` returns
// the left operand's type outright when it can never be falsy, `??` when it can
// never be nullish, `&&` when it can never be truthy. Otherwise a fallback
// written for a case that no longer exists — the object type used to be
// nullable, the narrowing already happened — stays in the type of every use of
// the result.

declare const o: { a: string };
declare const maybe: { a: string } | null;
declare const s: string;

// 1. An object type is never falsy, so the fallback is unreachable.
const r1 = o || { b: 1 };
export const q1: { a: string } = r1;

// 2. Same for `??` on a non-nullable left operand.
const r2 = o ?? { b: 1 };
export const q2: { a: string } = r2;

// 3. `false` is never truthy, so `&&` is just the left operand.
declare const no: false;
const r3 = no && { b: 1 };
export const q3: false = r3;

// 4. A nullable left operand still unions.
const r4 = maybe || { b: 1 };
export const q4: { a: string } = r4; // TS2322

// 5. `string` can be `""`, so `||` still unions there too.
const r5 = s || "x";
export const q5: "x" = r5; // TS2322

// 6. A bare type parameter is undecidable and keeps the union.
export function f<T>(t: T) {
  const r6 = t || { b: 1 };
  const q6: T = r6; // TS2322
  return q6;
}

// 7. The unreachable operand is still checked.
declare function g(x: string): void;
export const r7 = o || g(1); // TS2345
