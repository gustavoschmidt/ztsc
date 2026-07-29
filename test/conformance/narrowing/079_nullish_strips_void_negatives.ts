// `??` drops only `undefined`, `null` and `void` — nothing else — and the
// right operand is still part of the result.
declare const bv: boolean | void;
declare const sn: string | number | undefined;

// `boolean` is not `string`.
export const a: string = bv ?? "x";

// `number` survives: `string | number`.
export const b: string = sn ?? "x";

// The right operand is not dropped either.
export const cc: boolean = bv ?? 1;

// `void` on the RIGHT is untouched.
declare const v: void;
declare const su: string | undefined;
export const d: string = su ?? v;
