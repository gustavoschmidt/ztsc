// A string/numeric enum member is assignable to the literal type of its value
// (the OUT direction) — tsc treats an enum member as a subtype of its value.
// The reverse (a literal widening INTO the enum) stays rejected.
enum Dir {
  Fwd = "forward",
  Back = "backward",
}
type DirLit = "forward" | "backward";

// member -> full value union: OK
const a: DirLit = Dir.Fwd;
// member -> `string`: OK (already supported)
const b: string = Dir.Back;

// object-literal property with a contextual literal-union type: OK
type Wrap = { direction: DirLit };
const w: Wrap = { direction: Dir.Fwd };

// numeric enum member -> numeric-literal union: OK
enum Num {
  A = 1,
  B = 2,
}
const n: 1 | 2 = Num.A;

// negative control: a literal never widens into the enum.
const bad: Dir = "forward";
