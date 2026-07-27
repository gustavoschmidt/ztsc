// An object literal written for a still-generic MAPPED parameter
// (`c: { [K in keyof T]: T[K] }`) had no contextual type at all: a mapped type
// has no members to look up, so the per-property lookup found nothing. tsc's
// `getTypeOfPropertyOfContextualType` answers with the value template, the key
// bound to that property's name (`substituteIndexedMappedType`), so property
// `a` above is contextually `T['a']` — and a deferred type variable offers the
// contextual members of its apparent type, its base constraint.
//
// Two things were lost without it: a property value's callback had no
// contextual signature, so its parameters fell to implicit `any` (TS7006), and
// a property value's fresh literal widened, so the type parameter inferred the
// widened type.

// Callback value: `x` is `number` from the constraint's call signature.
declare function mf<T extends Record<string, (x: number) => void>>(c: {
  [K in keyof T]: T[K];
}): T;
export const z1 = mf({ a: (x) => x.toFixed() });

// Fresh boolean literal: kept, so `T` infers `{ a: { b: true } }`.
declare function mg<T extends Record<string, { b: boolean }>>(c: {
  [K in keyof T]: T[K];
}): T;
const r2 = mg({ a: { b: true } });
export const chk2: { a: { b: true } } = r2;

// Fresh string literal against a literal union: likewise kept.
declare function mh<T extends Record<string, { b: "x" | "y" }>>(c: {
  [K in keyof T]: T[K];
}): T;
const r3 = mh({ a: { b: "x" } });
export const chk3: { a: { b: "x" } } = r3;

// The non-mapped control, which always worked: the same call written with a
// bare `T` parameter.
declare function pf<T extends Record<string, (x: number) => void>>(c: T): T;
export const z4 = pf({ a: (x) => x.toFixed() });

// NEGATIVE: the parameter really is `number`, not `any` — a body that treats
// it as a string fails. With no contextual signature this reported nothing.
export const bad = mf({ a: (x) => x.toUpperCase() });

// NEGATIVE: the literal was kept EXACTLY, so `T` is `{ a: { b: true } }` and a
// `false` does not fit it.
export const bad2: { a: { b: false } } = r2;
