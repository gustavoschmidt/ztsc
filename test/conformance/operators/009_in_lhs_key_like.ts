// The left operand of `in` only has to be assignable to
// `string | number | symbol` as a WHOLE — tsc's `checkInExpression` accepts
// that alongside the per-facet test, which is what admits a key type no single
// facet matches.
export function pick<
  R extends Record<string, any>,
  K extends readonly (keyof R)[],
>(source: R, key: K[number], key2: keyof R) {
  // `K[number]` reduces to `keyof R`; both are `string | number | symbol`.
  return [key in source, key2 in source];
}

declare const o: object;

declare const sn: string | number;
export const a = sn in o;

declare const sym: symbol;
export const b = sym in o;

declare const sns: string | number | symbol;
export const cc = sns in o;

export function viaParam<T extends string>(k: T) {
  return k in o;
}
