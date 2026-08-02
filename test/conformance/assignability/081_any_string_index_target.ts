// A target string index signature whose type is exactly `any` short-circuits
// the whole index-signature relation for any non-primitive source (tsc
// `indexSignaturesRelatedTo`: `targetHasStringIndex && targetInfo.type &
// TypeFlags.Any` → related, guarded on `!sourceIsPrimitive`).
//
// That is what makes `Record<string, any>` the "any object" escape hatch it is
// in practice, and it is what `T extends Record<string, any>` — react-hook-
// form's `FieldValues`, and half the generic-constraint idioms built on it —
// relies on: an interface or class instance has no index signature of its own
// and no implied one, yet still satisfies it. `unknown` gets no such
// exemption (see 058), and neither do primitives.

interface Form {
    email: string;
    nested: { deep: string };
}
declare class Box {
    v: number;
    get(): number;
}
type Values = Record<string, any>;

declare const form: Form;
declare const box: Box;
declare const lit: { a: string };
declare const arr: string[];
declare const tup: [string, number];
declare const fn: () => void;

// Non-primitive sources: all accepted.
const a: Values = form;
const b: Values = box;
const c: Values = lit;
const d: Values = arr;
const e: Values = tup;
const f: Values = fn;

// The same relation as a type-argument constraint.
type Holder<T extends Values> = T[];
type H1 = Holder<Form>;
type H2 = Holder<Box>;

// Primitives get no exemption.
const g: Values = "s";
const h: Values = 1;
const i: Values = true;

// `unknown` is not `any`: the interface has no index signature to offer.
type Unknowns = Record<string, unknown>;
const j: Unknowns = form;
const k: Unknowns = box;
const l: Unknowns = lit;

export { a, b, c, d, e, f, g, h, i, j, k, l };
export type { H1, H2 };
