// Assignability between concrete strings, template patterns, and `string`.
type Pat = `a${string}b`;
const ok1: Pat = "ab";
const ok2: Pat = "axxxb";
const bad1: Pat = "axc";   // wrong tail -> TS2322
const bad2: Pat = "zab";   // wrong head -> TS2322

declare const s: string;
const bad3: Pat = s;       // string is not assignable to a pattern -> TS2322

// A pattern is assignable to `string`.
const toStr: string = "aQb" as Pat;

// Numeric hole pattern.
type NumPat = `x${number}`;
const n1: NumPat = "x42";
const n2: NumPat = "x-3.5";
const n3: NumPat = "xfoo";  // not numeric -> TS2322
