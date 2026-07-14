// T[keyof T] — the value union of a generic object (M16d).
type Vals<T> = T[keyof T];
type V = Vals<{ a: number; b: string }>;
const v1: number | string = null as any as V;
const v2: V = 5;
const v3: V = "s";
const vbad: V = true;   // TS2322 (boolean not number | string)
