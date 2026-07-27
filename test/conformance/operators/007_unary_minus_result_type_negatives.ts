// Negative side of the unary `-` result type: the `number`/`bigint` split has
// to stay observable, so a wrong result type is still an error.
declare const nv: never;
declare const an: any;
declare const bi: bigint;
declare const st: string;

const a: bigint = -nv; // number is not assignable to bigint
const b: bigint = -st; // number is not assignable to bigint
const c: number = -bi; // bigint is not assignable to number
const d = -bi + 1; // bigint and number do not mix
const e = -nv + 1n; // number and bigint do not mix
const f: bigint = -an; // `any` coerces to number

export { a, b, c, d, e, f };
