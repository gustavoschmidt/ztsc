// A type parameter that appears ONLY in the return type has no inference
// site. tsc resolves it from the call's contextual return type when there is
// one, and otherwise falls back to the parameter's constraint (or `unknown`
// when it has none, or its default when it has one). Crucially, a NESTED such
// call must not adopt the enclosing call's own still-unresolved inference
// variable as its answer: the contextual type it sees is the parameter type
// with the outer call's *known* inferences substituted, and an unresolved
// outer variable contributes nothing.
type GP = [number, number] & { _brand: "gp" };
type LP = [number, number] & { _brand: "lp" };

declare function pf<P extends GP | LP>(x: number, y: number): P;
declare function pair<Q extends GP | LP>(x: Q, y: Q): [Q, Q];
declare function idc<Q extends GP | LP>(x: Q): Q;
declare function pu<P>(x: number): P;
declare function pd<P extends GP | LP = LP>(x: number): P;

declare const gp: GP;
declare const nul: null;

// No context at all: the constraint.
const a = pf(1, 2);
export const aOk: GP | LP = a;
export const aBad: GP = a;

// Contextual return type on the OUTER call feeds the nested ones.
export const c: [GP, GP] = pair(pf(1, 2), pf(3, 4));

// No outer context, but an earlier argument already pinned `Q`.
const h = pair(gp, pf(3, 4));
export const hOk: [GP, GP] = h;

// No outer context and nothing pins `Q`: the nested call falls back to its
// own constraint rather than leaking `Q` into the result.
const f = idc(pf(1, 2));
export const fOk: GP | LP = f;
export const fBad: GP = f;

// Unconstrained, no context.
const u = pu(1);
export const uBad: GP = u;
export const uOk: unknown = u;

// A default wins over the constraint.
const d = pd(1);
export const dOk: LP = d;
export const dBad: GP = d;

// Direct contextual resolution still works.
export const b: GP = pf(1, 2);
export const bad2: null = nul;
