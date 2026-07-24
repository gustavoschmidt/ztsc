// Parameters<typeof F> is the tuple of ALL params; [i] selects the i-th.
// A rest-pattern `infer` in Parameters binds the whole source-param tuple,
// so [1]/[2] no longer collapse to param 0's type.
declare function f(a: string, b: number, c: boolean): void;
type P = Parameters<typeof f>;
const p1ok: number = null as any as P[1];
const p1bad: string = null as any as P[1];   // TS2322
const p2ok: boolean = null as any as P[2];
const p2bad: number = null as any as P[2];    // TS2322

// optional source param -> optional tuple element; rest -> rest element.
declare function g(a: string, b?: number, ...rest: boolean[]): void;
type Q = Parameters<typeof g>;
const q0: string = null as any as Q[0];
const q1ok: number | undefined = null as any as Q[1];
const q2ok: boolean = null as any as Q[2];
const q1bad: number = null as any as Q[1];     // TS2322 (optional -> |undefined)
