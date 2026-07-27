export {};
// A qualified enum member used as a TYPE (`x: E.A`) is the member's own
// nominal unit type: a subtype of its declared value literal and of the whole
// enum, distinct from every sibling.
enum S {
  A = "a",
  B = "b",
}
enum N {
  P = 1,
  Q = 2,
}
enum S2 {
  A = "a",
}

declare const sa: S.A;
declare const sb: S.B;
declare const sw: S;
declare const np: N.P;
declare const nw: N;
declare const str: string;
declare const num: number;
declare const an: any;

// POSITIVE
const p1: "a" = sa; // member -> its own value literal
const p2: S = sa; // member -> whole enum
const p3: string = sa; // string member -> string
const p4: "a" | "b" = sa; // member -> a union containing its value
const p5: S.A | S.B = sw; // whole enum -> the union of its members
const p6: S = sa as S.A;
const p7: 1 = np; // numeric member -> its own value literal
const p8: number = np;
const p9: N.P = 1; // matching numeric literal -> numeric member
const p10: N.P = num; // `number` widens INTO a numeric enum member
const p11: N = np;
const p12: S.A = an;
const p13: S.A = sa;

// NEGATIVE
const n1: S.A = "a"; // a string literal never widens into a string enum
const n2: S.B = sa; // distinct members do not relate
const n3: S.A = sw; // the whole enum is not any one member
const n4: S.A = str; // `string` never widens into a string enum
const n5: N.P = 2; // wrong member's value
const n6: N.P = nw; // whole numeric enum is not one member
const n7: S.A = S2.A; // same value, different enum: nominal
const n8: "b" = sa; // another member's value
const n9: null = sa;
const n10: number = sa; // a string member is not numberish
const n11: string = np; // a numeric member is not stringish
const n12: S.A = sb;

// Comparison overlap (TS2367): a member overlaps its own value and the whole
// enum, and nothing else.
declare const w: S;
if (sa === S.A) {
}
if (w === S.A) {
}
if (sa === sb) {
}
if (sa === S.B) {
}
