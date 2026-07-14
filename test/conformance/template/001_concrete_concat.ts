// Concrete template-literal types: every hole is a literal, so the type
// evaluates to a single string-literal (number/boolean holes stringify).
type Prefixed = `id-${42}`;
const a: Prefixed = "id-42";
const b: Prefixed = "id-43"; // wrong -> TS2322

type Flag = `flag:${true}`;
const c: Flag = "flag:true";
const d: Flag = "flag:false"; // wrong -> TS2322

type Empty = `${""}`;
const e: Empty = "";

type Nested = `x${`y${1}`}z`;
const f: Nested = "xy1z";
const g: Nested = "xyz"; // wrong -> TS2322
