// keyof of a mapped type reflects its key set (M16d, closing the M16b loop).
type Keys<T> = keyof { [K in keyof T]: T[K] };
type KM = Keys<{ a: number; b: string }>;
const k1: "a" | "b" = null as any as KM;
const kbad: "a" = null as any as KM;   // TS2322

// keyof over an explicit literal-keyed mapped type.
type M = { [K in "x" | "y"]: number };
type KX = keyof M;
const kx1: "x" | "y" = null as any as KX;
const kxbad: "x" = null as any as KX;   // TS2322
