// tsc's comparable relation exempts null/undefined from TS2367: an equality
// test against (or of) a nullish operand is never "no overlap" — even when
// the other side's type cannot be nullish. A non-nullish disjoint pair
// (string vs number) still reports.
declare const n: number;
declare const s: string;
declare const nu: null;
declare const ud: undefined;
declare const opt: number | undefined;

const a1 = n === null;
const a2 = s === undefined;
const a3 = nu === ud;
const a4 = opt != null;
const a5 = opt === null;
const bad = s === n;
void a1; void a2; void a3; void a4; void a5; void bad;
