// A string literal rejected by a union of string literals with a close member
// gets tsc's TS2820 ("Did you mean 'X'?") in place of plain TS2322; a literal
// with no near member stays TS2322. (getSuggestedTypeForNonexistentStringLiteralType)
type Dir = "north" | "south" | "east" | "west";
const a: Dir = "nrth"; // close to "north" -> TS2820
const b: Dir = "diagonal"; // no near member -> TS2322
