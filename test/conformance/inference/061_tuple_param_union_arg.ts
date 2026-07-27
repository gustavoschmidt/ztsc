// A TUPLE parameter matched against a UNION argument must infer through the
// union's tuple constituents.
//
// A union parameter hands the WHOLE argument to each of its type-parameter-
// bearing members, so `void | readonly [number, T]` against
// `void | readonly [number, string[]]` reaches the tuple arm of inference as
// (tuple, union) — which matched nothing, leaving `T` at its fallback. The
// `.array` arm already distributed over a union argument; the tuple arm did
// not. Reduced from excalidraw's `PromisePool<T>` constructor, whose parameter
// is `IterableIterator<Promise<void | readonly [number, T]>>`.

// POSITIVE: `T` must be inferred, so each of these is the *inferred* type, not
// the type-parameter fallback. Each line's error text names what was inferred.

declare function u1<T>(x: void | readonly [number, T]): T;
declare function u2<T>(x: void | [number, T]): T;
declare function u3<T>(x: undefined | readonly [number, T]): T;
declare function u4<T>(x: string | readonly [number, T]): T;
declare function u5<T>(x: void | readonly [number, T] | readonly [T, T]): T;

declare const v1: void | readonly [number, string[]];
declare const v2: void | [number, string[]];
declare const v3: undefined | readonly [number, string[]];
declare const v4: string | readonly [number, string[]];

export const a1: null = u1(v1); // TS2322 'string[]'
export const a2: null = u2(v2); // TS2322 'string[]'
export const a3: null = u3(v3); // TS2322 'string[]'
export const a4: null = u4(v4); // TS2322 'string[]'
export const a5: null = u5(v1); // TS2322 'string[]'

// Regression: a bare tuple parameter (no union on either side) still infers.
declare function b1<T>(x: readonly [number, T]): T;
declare const w1: readonly [number, string[]];
export const b1r: null = b1(w1);

// Regression: the naked-type-parameter union member is unaffected.
declare function n1<T>(x: void | T): T;
declare const y1: void | string[];
export const n1r: null = n1(y1);

// Regression: an array member of a union parameter still infers.
declare function m1<T>(x: void | T[]): T;
export const m1r: null = m1(y1);

// Through a generic wrapper: the shape the PromisePool constructor has.
declare function pool<T>(
  s: IterableIterator<Promise<void | readonly [number, T]>>,
): T[];
declare function gen(): Generator<Promise<void | readonly [number, string[]]>>;
declare function iter(): IterableIterator<
  Promise<void | readonly [number, string[]]>
>;
export const g1: null = pool(gen()); // TS2322 'string[][]'
export const g2: null = pool(iter()); // TS2322 'string[][]'

// NEGATIVE: an argument union with no tuple constituent infers nothing from
// the tuple member, so the call is rejected on the argument itself.
declare const z1: void | { a: 1 };
export const bad = u1(z1); // TS2345
