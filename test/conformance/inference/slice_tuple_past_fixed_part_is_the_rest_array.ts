// tsc's `sliceTupleType` cuts at the tuple's FIXED length, not its arity:
//
//     return index > target.fixedLength ? getRestArrayTypeOfTupleType(type) || createTupleType(emptyArray) : …
//
// so a slice starting past the last fixed position answers with the rest ARRAY
// the variable tail spans. `inferFromTupleTypes`' `[...T, ...U]` middle relies
// on it, because the implied arity the call site supplies may run PAST the
// source's own positions — tsc has no guard there for the same reason.
//
// Oracle-verified against tsgo 7.0.2: every line below is clean, and the
// inferred types are pinned by the annotated consumers.

function curry<T extends unknown[], U extends unknown[], R>(f: (...args: [...T, ...U]) => R, ...a: T) {
    return (...b: U) => f(...a, ...b);
}

// A fully fixed parameter list: the implied arity never exceeds the source.
const fn1 = (a: number, b: string, c: boolean, d: string[]) => 0;
const c1: (b: string, c: boolean, d: string[]) => number = curry(fn1, 1);
const c2: (c: boolean, d: string[]) => number = curry(fn1, 1, "abc");
const c3: (d: string[]) => number = curry(fn1, 1, "abc", true);
const c4: () => number = curry(fn1, 1, "abc", true, ["x", "y"]);

// `[number, boolean, ...string[]]`: fixed length 2, arity 3. An implied arity
// of 4 runs past it, so `T` saturates to the whole tuple and `U` is the rest
// array `string[]`. Answering the EMPTY tuple instead left `T := [number,
// boolean, string, string, ...unknown[]]` — five positions for a three-position
// source — and the call was a TS2345 on `fn2` itself. Written WITHOUT an
// annotation on purpose: a wider `U` still satisfies a `(...args: string[])`
// target, so only the bare call shows the difference.
const fn2 = (x: number, b: boolean, ...args: string[]) => 0;
const c10: (x: number, b: boolean, ...args: string[]) => number = curry(fn2);
const c11: (b: boolean, ...args: string[]) => number = curry(fn2, 1);
const c12: (...args: string[]) => number = curry(fn2, 1, true);
const c13 = curry(fn2, 1, true, "abc", "def");
const c13b: (...args: string[]) => number = c13;

// A pure rest source: every split lands inside the variable part.
const fn3 = (...args: string[]) => 0;
const c20: (...args: string[]) => number = curry(fn3);
const c21: (...args: string[]) => number = curry(fn3, "abc", "def");

// The slice that starts exactly AT the variable part is unchanged (a lone rest
// element collapses to its array), and a leading fixed run is still kept.
declare function tail<H, R extends unknown[]>(t: [H, ...R]): R;
const t1: [boolean, ...number[]] = tail<string, [boolean, ...number[]]>(["a", true, 1, 2]);
