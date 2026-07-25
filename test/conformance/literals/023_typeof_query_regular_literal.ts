// A `typeof x` type query yields the REGULAR (non-widening) literal type, so a
// value annotated with it does not re-widen when used as an object-literal
// property (tsc's getRegularTypeOfLiteralType). Single query and a union of
// typeof-const queries must both stay literal — all diagnostic-free.
const A = "ACTIVE";
type TA = typeof A;
declare const x: TA;
const o = { s: x };
const t: TA = o.s;

const P = "P",
  Q = "Q";
type PQ = typeof P | typeof Q;
declare const y: PQ;
const o2 = { s: y };
const t2: PQ = o2.s;
