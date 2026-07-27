// The result type of unary `-` is `bigint` only when the operand actually
// carries a bigint constituent (tsc's getUnaryResultType tests
// `maybeTypeOfKind(t, BigIntLike)`). `never` has no constituents and `any`
// is not bigint-like, so both coerce to `number` — treating them as bigint
// (they are vacuously *assignable* to bigint) turned `-x + 1` into
// TS2365 "Operator '+' cannot be applied to types 'bigint' and '1'".
declare const nv: never;
declare const an: any;
declare const bi: bigint;
declare const bl: 1n;
declare const st: string;
declare const nu: number;

// number results
const a: number = -nv;
const b: number = -an;
const c: number = -st;
const d: number = -nu;
const e = -nv + 1;
const f = -an + 1;

// bigint results
const g: bigint = -bi;
const h: bigint = -bl;
const i = -bi + 1n;

export { a, b, c, d, e, f, g, h, i };
