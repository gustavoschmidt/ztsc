// The classic ReturnType pattern: infer from a function type's return
// position (covariant).
type Ret<T> = T extends (...args: any[]) => infer R ? R : never;

const a: Ret<() => string> = "hi";
const b: Ret<(x: number) => boolean> = true;
const c: Ret<() => string> = 5; // wrong -> TS2322

// infer from a parameter position.
type Arg0<T> = T extends (a: infer A) => any ? A : never;
const d: Arg0<(n: number) => void> = 5;
const e: Arg0<(n: number) => void> = "x"; // wrong -> TS2322
