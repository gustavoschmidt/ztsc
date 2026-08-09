// A CONTRAVARIANT inference candidate beats a covariant one unless the
// covariant type is a SUBTYPE of it — tsc's `getInferredType`. The test is the
// subtype relation, not assignability, and the two disagree on exactly one
// shape that matters here: an object literal type is *assignable* to an index
// signature it does not declare (`const r: { [k: string]: true } = {}` is
// legal, via tsc's `getImplicitIndexInfoOfType`) but is not a *subtype* of it.
//
// Reading that gap as "subtype" let the seed argument's `{}` survive as the
// covariant inference and threw away the annotated accumulator, so the fold's
// result type was `{}` — and every later read off it was an implicit-'any'
// element access. Excalidraw's
// `elements.reduce((acc: Record<ExcalidrawElement["id"], true>, el) => …, {})`
// is the shape, and it reported TS7053 on the two element writes below it.
//
// (Written lib-free: `fold` stands in for `Array.prototype.reduce`'s
// `reduce<U>(cb, initialValue: U): U` overload.)

declare function fold<U>(cb: (acc: U) => U, init: U): U;

type Ids = { [k: string]: true };

// `U` must infer `Ids` (contravariant, from `acc`), not `{}` (covariant, from
// `init`): `{}` is assignable to `Ids` but is not a subtype of it.
const ids = fold((acc: Ids) => acc, {});
const one: true = ids["a"];

// Argument order is not what decides it.
declare function foldFlipped<U>(init: U, cb: (acc: U) => U): U;
const ids2 = foldFlipped({}, (acc: Ids) => acc);
const two: true = ids2["b"];

// The covariant candidate still wins when it IS a subtype of the
// contravariant one: `{ [k: string]: true }` is a subtype of `{}`, so `U`
// stays the wider covariant reading and the index read below is an error
// neither compiler should have to invent.
declare function widen<U>(cb: (acc: U) => U, init: U): U;
const wide = widen((acc: {}) => acc, ids);
const three: {} = wide;
