// An `infer` variable declared by a conditional's `extends` clause stays in
// scope throughout that conditional's true branch — including inside NESTED
// conditionals' own branches, not only their check clause. Distilled from the
// dogfood project's react-hook-form `PathValueImpl` / `ValidPathPrefixImpl`,
// where `K`/`R` inferred by an outer `P extends `${infer K}.${infer R}`` are
// referenced deep inside nested conditionals' true branches. Before the fix
// ztsc scoped infer vars to a single conditional node, so a nested conditional
// overwrote the outer scope and these references failed with TS2304
// ("Cannot find name 'K'").

// outer infer B (object pattern) used in a nested conditional's true branch
type Second<T> = T extends { a: infer A; b: infer B }
  ? A extends string ? B : never
  : never;
const x: Second<{ a: string; b: number }> = 3;
const xw: Second<{ a: string; b: number }> = "no"; // TS2322

// outer template-literal infer R used in a nested conditional's true branch
type AfterA<P extends string> = P extends `${infer K}.${infer R}`
  ? K extends "a" ? R : "no"
  : "none";
const y: AfterA<"a.rest.here"> = "rest.here";
const yw: AfterA<"a.rest.here"> = "no"; // TS2322
const z: AfterA<"q.b"> = "no";
const zw: AfterA<"q.b"> = "b"; // TS2322

// outer infer K/V used TWO nested conditionals deep (the PathValueImpl depth)
type Deep<T> = T extends { k: infer K; v: infer V }
  ? K extends string
    ? V extends number ? [K, V] : never
    : never
  : never;
const w: Deep<{ k: "x"; v: 5 }> = ["x", 5];
const ww: Deep<{ k: "x"; v: 5 }> = ["x", 6]; // TS2322
