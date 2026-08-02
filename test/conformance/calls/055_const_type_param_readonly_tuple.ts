// The const-context half of `const` type parameters: an ARRAY LITERAL argument
// whose contextual type is a `const` type parameter infers a TUPLE, readonly
// unless the contextual type is mutable-array-like (tsc's `checkArrayLiteral`
// builds the tuple `readonly` only when `!someType(contextualType,
// isMutableArrayLikeType)`), and the context propagates into nested literals
// the way `isConstContext` walks up through array elements and property
// assignments.

declare function konst<const T>(x: T): T;
declare function plain<T>(x: T): T;

const t = konst([1, 2, 3]);
const w = plain([1, 2, 3]);

// NEGATIVE — a TUPLE of the literal elements, so a shorter one is rejected.
const bad_t: readonly [1, 2] = t;
// The control widened to an array, so it has no fixed length.
const bad_w: readonly [1, 2, 3] = w;

// Nested literals recurse: the inner object is in the same const context.
const nested = konst([{ a: 1 }, "s"]);
const bad_nested: readonly [{ a: number }, "s"] = nested;

// The context reaches a literal one level down, under a property whose type is
// the `const` parameter.
declare function boxed<const T>(x: { v: T }): T;
const inner = boxed({ v: [1, 2] });
const bad_inner: readonly [1, 2, 3] = inner;

// A MUTABLE array constraint keeps the tuple MUTABLE — a readonly one would
// not satisfy `T extends unknown[]` at all, so the parameter would be clamped
// back to the constraint and the element literals lost.
declare function mut<const T extends unknown[]>(x: T): T;
const m = mut([1, 2]);
const bad_m: [1, 2, 3] = m;

// A READONLY array constraint keeps the tuple readonly; either way the
// elements are the literals, which is what the negative turns on.
declare function ro<const T extends readonly unknown[]>(x: T): T;
const r = ro([1, 2]);
const bad_r: readonly [1, 2, 3] = r;

// An empty literal is still a tuple.
const e = konst([]);
const bad_e: readonly [1] = e;
