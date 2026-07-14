// Indexed access distributes over a union index: T[A | B] === T[A] | T[B].
type At<T, K extends keyof T> = T[K];
type R = At<{ a: number; b: string; c: boolean }, "a" | "b">;
const r1: number | string = null as any as R;
const r2: R = 1;
const r3: R = "s";
const rbad: R = true;   // TS2322 (boolean not number | string)

// Direct union index on a concrete object.
type Obj = { x: number; y: string; z: boolean };
type XY = Obj["x" | "y"];
const xy1: number | string = null as any as XY;
const xybad: boolean = null as any as XY;   // TS2322
