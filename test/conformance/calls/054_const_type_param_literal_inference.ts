// A `const` TYPE PARAMETER (TS 5.0, `f<const T>(…)`) makes inference from a
// literal argument behave as if the argument had been written `as const`: the
// literal type is kept instead of widened, and an object literal's properties
// keep their literal types too. tsc folds this into the same
// `getCovariantInference` test that a primitive constraint satisfies
// (`hasPrimitiveConstraint(tp) || isConstTypeVariable(tp)`), plus the
// `isConstContext` arm that reads the argument's contextual type.

declare function konst<const T>(x: T): T;
declare function plain<T>(x: T): T;

// A fresh primitive literal survives.
const s = konst("a");
const n = konst(1);
const b = konst(true);

// The control: without `const` the same call widens (the parameter is not at
// the top level of the return type here — see the `id` control below — so
// widening is what tsc does).
const ws = plain("a");

// An object literal keeps its property literal types.
const o = konst({ kind: "circle", radius: 1 });
const wo = plain({ kind: "circle", radius: 1 });

// NEGATIVE — the kept literals are what the checks below turn on.
const bad_s: "b" = s;
const bad_n: 2 = n;
const bad_b: false = b;
const bad_o: { kind: "square"; radius: 1 } = o;

// The widened controls really are widened.
const wide_s: "a" = ws;
const wide_o: { kind: "circle"; radius: 1 } = wo;

// A non-literal argument is unaffected: `const` keeps what the expression
// already has, it does not narrow.
declare const v: string;
const kv = konst(v);
const bad_kv: "a" = kv;

// A variable holding an array is not a literal EXPRESSION, so there is no
// const context to enter — it keeps its own (already widened) type.
const arr = [1, 2];
const ka = konst(arr);
const bad_ka: readonly [1, 2] = ka;

// `const` on a parameter that is already at the top level of the return type
// changes nothing — that position never widened.
declare function id<const T>(x: T): T;
const i1 = id("a");
const bad_i1: "b" = i1;

// A `const` parameter under a REST parameter still keeps each literal, and the
// candidates union rather than widen.
declare function anyOf<const T>(...xs: T[]): T;
const u = anyOf("a", "b");
const bad_u: "a" = u;
