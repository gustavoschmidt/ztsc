// Generic indexed access T[K] where K extends keyof T (M16d).
function pick<T, K extends keyof T>(o: T, k: K): T[K] { return o[k]; }
const o = { a: 1, b: "s" };
const r1: number = pick(o, "a");
const r2: string = pick(o, "b");
const r3: number = pick(o, "b");   // TS2322 (string -> number)
pick(o, "c");                      // TS2345 ("c" not in "a" | "b")

type Get<T, K extends keyof T> = T[K];
type G = Get<{ a: number; b: string }, "a">;
const g1: number = null as any as G;
const gbad: string = null as any as G;   // TS2322
