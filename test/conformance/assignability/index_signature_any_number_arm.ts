// tsc's `indexSignaturesRelatedTo` relates ONE index info of the target
// vacuously when the source is not primitive, the target has a string index
// signature somewhere, and THAT info's value type is `any`. The rule is run
// for every info of the target, the number one included — so a target spelled
// `{ [x: string]: any; [x: number]: any }` is satisfied by any non-primitive
// source, including an interface, a class instance, a function and a class
// value, none of which has an index signature of its own or an implied one.
// This is the shape of styled-components' `NonReactStatics<any>`, hence of
// `AnyStyledComponent`.
interface Named {
  foo(): void;
}
class Cls {
  x = 1;
}
declare const n: Named;
declare const l: { foo(): void };
declare const c: Cls;
declare const f: () => void;
declare const arr: string[];
declare const s: string;
declare const num: number;
declare const sym: symbol;
declare const empty: {};

// A. string + number index, both `any`: every non-primitive source passes.
type A = { [x: string]: any; [x: number]: any };
export const a1: A = n;
export const a2: A = l;
export const a3: A = c;
export const a4: A = f;
export const a5: A = Cls;
export const a6: A = arr;
export const a7: A = empty;
export const a8: A = s; // primitive: no exemption
export const a9: A = num; // primitive
export const a10: A = sym; // primitive

// B. NUMBER index only — the target has no string index, so nothing is
// vacuous and a source without a numeric index fails.
type B = { [x: number]: any };
export const b1: B = n;
export const b2: B = c;
export const b3: B = l; // implied index, no numeric names: passes
export const b4: B = arr;

// C. string index only, `any`.
type C = { [x: string]: any };
export const c1: C = n;
export const c2: C = c;
export const c3: C = s; // primitive

// D. `unknown` is not `any`: neither info is exempt.
type D = { [x: string]: unknown; [x: number]: unknown };
export const d1: D = n;
export const d2: D = c;

// E. the exemption is per-info: the number info here is not `any`.
type E = { [x: string]: any; [x: number]: string };
export const e1: E = n;

// F. ...and neither is the string one.
type F = { [x: string]: string; [x: number]: any };
export const f1: F = n;

// G. an intersection source is not primitive, even with a primitive member.
type G = { [x: string]: any; [x: number]: any };
declare const sn: string & Named;
declare const se: string & {};
export const g1: G = sn;
export const g2: G = se;

// H. the mapped-type spelling of the same target (`NonReactStatics<any>` is
// `{ [K in Exclude<keyof any, ...>]: any }`, which materializes both infos).
type H = { [K in Exclude<keyof any, "zz">]: any };
export const h1: H = n;
export const h2: H = c;
export const h3: H = s; // primitive
