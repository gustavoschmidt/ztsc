// Which constituent of a callable INTERSECTION does a conditional's `infer`
// read? tsc's `getSignaturesOfType` concatenates an intersection's
// constituents' signatures in declaration order and `inferFromSignatures`
// pairs the source and pattern lists from the END, so a single-signature
// pattern reads the LAST callable constituent, and within it its last
// signature. Every line below is the oracle's answer, expressed as
// assignability so the verdict does not depend on how a type is printed.

type A = (() => "x") & (() => "y");
type RA = A extends () => infer R ? R : never;
declare const ra: RA;
const a_x: "x" = ra; // TS2322: RA is "y", the LAST constituent
const a_y: "y" = ra;

// A third constituent wins over both.
type D = (() => "x") & (() => "y") & (() => "z");
type RD = D extends () => infer R ? R : never;
declare const rd: RD;
const d_x: "x" = rd; // TS2322
const d_y: "y" = rd; // TS2322
const d_z: "z" = rd;

// A non-callable member in between changes nothing — it carries no signature.
type B = (() => "x") & { a: 1 } & (() => "y");
type RB = B extends () => infer R ? R : never;
declare const rb: RB;
const b_x: "x" = rb; // TS2322
const b_y: "y" = rb;

// An OVERLOAD SET is one constituent whose own last signature is what counts,
// so order decides between it and a plain function member.
declare function ov(a: string): "ov1";
declare function ov(a: number): "ov2";
type E = typeof ov & (() => "plain");
type RE = E extends (...args: any[]) => infer R ? R : never;
declare const re: RE;
const e_1: "ov1" = re; // TS2322
const e_2: "ov2" = re; // TS2322
const e_p: "plain" = re;

type F = (() => "plain") & typeof ov;
type RF = F extends (...args: any[]) => infer R ? R : never;
declare const rf: RF;
const f_1: "ov1" = rf; // TS2322
const f_2: "ov2" = rf;
const f_p: "plain" = rf; // TS2322

// A CONTRAVARIANT position (a parameter) follows the same constituent.
type H = ((a: "x") => void) & ((a: "y") => void);
type RH = H extends (a: infer P) => void ? P : never;
declare const rh: RH;
const h_x: "x" = rh; // TS2322
const h_y: "y" = rh;

// The shapes the rule was originally written for still resolve: an overload
// set intersected with a namespace value object, and a plain function
// intersected with its statics.
declare function timer(cb: () => void, ms: number): number;
declare function timer(cb: (a: string) => void, ms: number, a: string): "handle";
type Timers = typeof timer & { unref(): void };
type RT = ReturnType<Timers>;
declare const rt: RT;
const t_h: "handle" = rt;

declare const icon: ((props: { size: number }) => string) & { displayName: string };
type RI = typeof icon extends (props: infer P) => any ? P : never;
declare const ri: RI;
const i_p: { size: number } = ri;
const i_bad: { size: string } = ri; // TS2322

export { a_x, a_y, d_x, d_y, d_z, b_x, b_y, e_1, e_2, e_p, f_1, f_2, f_p };
export { h_x, h_y, t_h, i_p, i_bad };
