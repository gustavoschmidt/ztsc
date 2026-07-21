// A fresh object literal passed to a bare type-param parameter (`f<T extends
// C>(v: T)`) is contextually typed by the type param's instantiated
// constraint, so a discriminant property whose constraint type is a literal
// keeps that literal instead of widening. Without it the widened
// `{ type: string }` fails `T extends C`, and `T` is clamped to the whole
// constraint — losing the argument's real (narrow) shape. Mirrors tsc's
// `getContextualTypeForArgument` falling back to the instantiated constraint.

type Shape = { type: 'a'; x: number } | { type: 'b'; y: number };
declare function id<T extends Shape>(v: T): T;

// Positive: the fresh literal's discriminant stays `'a'`, so `T` is the narrow
// member and the result is usable where that member is expected.
const r1 = id({ type: 'a', x: 1 });
const ok1: { type: 'a'; x: number } = r1; // ok: literal preserved

// Positive: a single-member constraint (the geojson `AllGeoJSON` shape, where
// `type` is a string literal on every member).
type Feat = { type: 'Feature'; geometry: number; properties: object };
declare function truncate<T extends Feat>(v: T): T;
const r2 = truncate({ type: 'Feature', geometry: 1, properties: {} });
const ok2: 'Feature' = r2.type; // ok: `type` stays `'Feature'`

// Positive: the narrow shape flows through a second generic call.
declare function wrap<U extends Shape>(v: U): U[];
const r3 = wrap({ type: 'b', y: 2 });
const ok3: { type: 'b'; y: number }[] = r3; // ok

// Negative control: a non-fresh object *variable* is already widened
// (`type: string`) before the call, so it still fails the constraint — the
// contextual constraint only reaches a literal argument node.
const obj = { type: 'a', x: 1 };
const bad1 = id(obj); // error: { type: string } not assignable to Shape

// Negative control: a fresh literal missing a required property.
const bad2 = id({ type: 'a' }); // error: missing 'x'
