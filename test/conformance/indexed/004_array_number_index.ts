// A[number] on an array / tuple selects the element type (M16d).
type El<A extends readonly any[]> = A[number];
type E1 = El<[string, number]>;
const e1a: string | number = null as any as E1;
const e1bad: boolean = null as any as E1;   // TS2322

type E2 = El<number[]>;
const e2: number = null as any as E2;
const e2bad: string = null as any as E2;    // TS2322

function firstish<T>(a: T[]): T { return a[0]; }
const n: number = firstish([1, 2, 3]);
