// A left operand that is not assignable to `string | number | symbol` as a
// whole is still an error, reported by the relation itself.
declare const o: object;

declare const b: boolean;
export const r1 = b in o;

declare const sb: string | boolean;
export const r2 = sb in o;

declare const obj: { a: number };
export const r3 = obj in o;

export function viaParam<T extends boolean>(k: T) {
  return k in o;
}
