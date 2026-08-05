// tsc's `inferToMultipleTypes`: with a UNION source and a union parameter,
// each non-variable target constituent is inferred against each SOURCE
// constituent on its own, and the naked type variable then receives the
// union of the constituents no other member matched. Handing the whole
// source to the wrapper member and standing the variable down because the
// wrapper inferred loses every constituent the wrapper did not account for.
declare function f<T>(x: T | T[]): T;
declare const u: string | string[] | undefined;

// `T[]` matches only the `string[]` constituent, so `T` takes the other
// two: `string | undefined`, not `string`.
export const r = f(u);
export const rOk: string | undefined = r;

// Negative control: it is not `string` (and not `any`).
export const rBad: string = r;

// Negative control: the wrapper still answers alone when it matches every
// constituent — `T` is `number`, and nothing widens it to the array.
declare function g<T>(x: T | readonly T[]): T[];
declare const nums: number[];
export const gv = g(nums);
export const gvOk: number[] = gv;
export const gvBad: string[] = gv;

// Negative control: the concrete-member subtraction that was already there
// is unchanged — `S | undefined` against `number | undefined` gives
// `S = number`.
declare function h<S>(x: S | undefined): S;
declare const su: number | undefined;
export const hv = h(su);
export const hvOk: number = hv;
export const hvBad: string = hv;
