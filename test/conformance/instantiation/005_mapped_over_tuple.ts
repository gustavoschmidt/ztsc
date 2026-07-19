// A mapped type applied to a tuple maps element-wise and yields a tuple
// (the shape Promise.all's tuple overload relies on).
type MP<T> = { -readonly [P in keyof T]: Awaited<T[P]> };
type T1 = MP<[Promise<number>, Promise<string>]>;
declare const t1: T1;
const n1: number = t1[0];
const s1: string = t1[1];
const bad: number = t1[1]; // TS2322
type Boxes<T> = { [P in keyof T]: { v: T[P] } };
type T2 = Boxes<[1, "a"]>;
declare const t2: T2;
const one: { v: 1 } = t2[0];
