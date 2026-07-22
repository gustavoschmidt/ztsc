// Relational operators (< > <= >=): tsc admits a comparison iff BOTH sides
// are number/bigint-like, or NEITHER side is number-like and one is
// comparable to the other (structurally). Not a Date special case.
declare const d1: Date;
declare const d2: Date;
declare const n: number;
declare const s1: string;
declare const s2: string;
declare const o1: { a: number };
declare const o2: { a: number };

const ok1 = d1 > d2; // Date vs Date — allowed (comparable, neither number-like)
const ok2 = s1 < s2; // string vs string — allowed
const ok3 = o1 >= o2; // structurally-equal object types — allowed
const ok4 = n > 3; // number vs number — allowed

const bad1 = d1 > n; // TS2365: mixed — one side number-like, other not
const bad2 = d1 < s1; // TS2365: neither number-like but not comparable
