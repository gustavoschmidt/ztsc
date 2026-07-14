// Integration: the M16 deferral machinery composes without blowing the depth
// budget (M16d). A conditional whose check is a generic indexed access, a
// mapped type over keyof of a generic, and a recursive mapped type.

// (1) conditional over a generic indexed access
type IsStr<T, K extends keyof T> = T[K] extends string ? "yes" : "no";
type A = IsStr<{ a: string; b: number }, "a">;
const a: "yes" = null as any as A;
const abad: "no" = null as any as A;   // TS2322

// (2) mapped over keyof of a generic (identity clone), then indexed
type Clone<T> = { [K in keyof T]: T[K] };
type C = Clone<{ a: number; b: string }>;
const cbad: C = { a: 1, b: 2 };        // TS2322 (b: number not string)

// (3) recursive mapped type: deep readonly
type DeepReadonly<T> = { readonly [K in keyof T]: T[K] extends object ? DeepReadonly<T[K]> : T[K] };
type D = DeepReadonly<{ a: number; b: { c: string } }>;
declare const d: D;
const x: number = d.a;
d.a = 5;                               // TS2540 (readonly)
