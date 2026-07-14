// `as never` key filtering (the Omit idiom).
type MyOmit<T, K> = { [P in keyof T as P extends K ? never : P]: T[P] };
interface Bar { a: number; b: string; c: boolean; }

declare const om: MyOmit<Bar, "b">;
const oa: number = om.a;
const oc: boolean = om.c;
const ob = om.b; // TS2339 (b filtered out)

// Filter everything -> empty object.
type DropAll<T> = { [P in keyof T as never]: T[P] };
declare const d: DropAll<Bar>;
const da = d.a; // TS2339
