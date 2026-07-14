// Multiple distinct infer sites in one extends clause.
type Pair<T> = T extends [infer A, infer B] ? { a: A; b: B } : never;
const a: Pair<[number, string]> = { a: 1, b: "x" };
const b: Pair<[number, string]> = { a: "x", b: "x" }; // wrong a -> TS2322

// The SAME infer name in two covariant positions unions the candidates.
type Both<T> = T extends { x: infer U; y: infer U } ? U : never;
const c: Both<{ x: number; y: string }> = 5;
const d: Both<{ x: number; y: string }> = "s";
const e: Both<{ x: number; y: number }> = 5;
const f: Both<{ x: number; y: number }> = "s"; // wrong: U is number -> TS2322
