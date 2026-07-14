// A homomorphic map over a tuple/array preserves its tuple/array-ness and
// per-element types.
type Id<T> = { [K in keyof T]: T[K] };

type TupR = Id<[number, string, boolean]>;
declare const t: TupR;
const t0: number = t[0];
const t1: string = t[1];
const tbad: number = t[1]; // TS2322 (element 1 is string)

type ArrR = Id<number[]>;
declare const a: ArrR;
const ae: number = a[0];
const abad: string = a[0]; // TS2322
