// A template-literal EXPRESSION argument (`` `x.${i}` ``) is contextually typed
// by the parameter during generic inference, so its template-literal *type* is
// preserved as the inference candidate when the type parameter's constraint is
// string-like — tsc's isTemplateLiteralContextualType. Companion to case 032,
// which covers plain string literals under a template contextual type; here the
// argument itself is a template expression with a non-literal substitution.
//
// Each `const z: 0 = r` below is an assertion device: the TS2322 message prints
// the inferred type, so the snapshot pins WHICH type was inferred, not merely
// that inference happened.

declare const i: number;

declare function kS<N extends string>(x: N): N;
declare function kU<N extends "a" | `b.${number}`>(x: N): N;
declare function kN<N>(x: N): N;

// KEEP: a `string` constraint is string-like, so the template-literal type
// survives instead of widening to `string`.
const rS = kS(`x.${i}`);
const zS: 0 = rS; // TS2322 — Type '`x.${number}`' is not assignable to type '0'.

// KEEP under a union constraint: the matching template constituent is inferred,
// not the whole constraint union (no constraint erasure).
const rU = kU(`b.${i}`);
const zU: 0 = rU; // TS2322 — Type '`b.${number}`' is not assignable to type '0'.

// WIDEN: an UNCONSTRAINED type parameter has no string-like contextual type, so
// the candidate widens to `string` as before.
const rN = kN(`x.${i}`);
const zN: 0 = rN; // TS2322 — Type 'string' is not assignable to type '0'.

// Unchanged control: a plain string literal under a `string` constraint still
// keeps its literal type.
const rL = kS("lit");
const zL: 0 = rL; // TS2322 — Type '"lit"' is not assignable to type '0'.
