// Concrete mapped type over a literal-union key set. Materializes eagerly to
// an object with one prop per key.
type Flags = { [K in "a" | "b" | "c"]: boolean };
declare const f: Flags;
const a: boolean = f.a;
const b: boolean = f.b;

// Wrong value type -> TS2322.
const w: string = f.a;

// Identity key mapping: `{ [K in "x"|"y"]: K }` = `{ x: "x"; y: "y" }`.
type Names = { [K in "x" | "y"]: K };
declare const n: Names;
const nx: "x" = n.x;
const ny: "y" = n.y;
const nbad: "x" = n.y; // TS2322
