// Element access `o['k']` with a string-literal key that is not a property and
// is not covered by a string index is an implicit-'any' element access — tsc
// reports TS7053 (implicit any), NOT the missing-property TS2339 that dotted
// access `o.k` produces. Under noImplicitAny:false the TS7053 is suppressed and
// the result is `any`; the conformance harness runs strict, so it fires here.
declare const o: { a: number };

// element access, missing key -> TS7053 (implicit-any element access)
const w = o['b'];

// dotted access, missing key -> TS2339 (negative control: NOT suppressed)
const x = o.b;

// valid element access -> no error (negative control)
const y = o['a'];

export { w, x, y };
