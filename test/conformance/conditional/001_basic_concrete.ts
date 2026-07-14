// Concrete conditional types: the check type is fully known, so the
// conditional resolves eagerly to one branch.
type IsString<T> = T extends string ? "yes" : "no";

const a: IsString<string> = "yes";
const b: IsString<"lit"> = "yes"; // string literal is assignable to string
const c: IsString<number> = "no";

// Wrong branch selected -> TS2322.
const d: IsString<number> = "yes";
const e: IsString<string> = "no";

// Nested conditional in the true branch.
type Kind<T> = T extends string ? (T extends "a" ? 1 : 2) : 3;
const f: Kind<"a"> = 1;
const g: Kind<"b"> = 2;
const h: Kind<number> = 3;
const i: Kind<"a"> = 2; // wrong -> TS2322
