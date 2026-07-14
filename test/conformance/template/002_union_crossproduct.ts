// A union hole expands the template to the cross-product of concatenations.
type AB = `a${"x" | "y"}b`;
const a1: AB = "axb";
const a2: AB = "ayb";
const a3: AB = "azb"; // not in the cross-product -> TS2322

type Pair = `${"a" | "b"}-${"c" | "d"}`;
const p1: Pair = "a-c";
const p2: Pair = "b-d";
const p3: Pair = "a-d";
const p4: Pair = "c-a"; // wrong -> TS2322

// A `boolean` hole enumerates as "false" | "true".
type Bool = `v=${boolean}`;
const b1: Bool = "v=true";
const b2: Bool = "v=false";
const b3: Bool = "v=maybe"; // wrong -> TS2322
