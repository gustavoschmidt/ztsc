// A trailing parameter is optional at the call site when its type ACCEPTS
// `void`, and a union accepts void as soon as ONE member is void.
//
// tsc writes the test as `filterType(type, acceptsVoid)` and asks whether the
// result is `never`; ztsc required every member of a union to be void, which
// is the opposite quantifier. The type that exposed it is
// `Promise`'s executor: `resolve` is `(value: T | PromiseLike<T>) => void`,
// so at `T = void` it is `void | PromiseLike<void>` and
// `new Promise<void>((resolve) => resolve())` reported TS2554.
//
// instantiation/011_void_param_arity.ts covers the bare `(x: void)` half of
// the same rule, on the assignability side.

export const promised = () =>
  new Promise<void>((resolve) => {
    resolve();
  });

// The assignability side of the same rule: such a signature is nullary, so it
// is assignable to a nullary function type. (This is rxjs's `Subscriber`
// `complete`, which the relation used to reject.)
declare const complete: (value: void | PromiseLike<void>) => void;
export const asNullary: () => void = complete;

// The union directly.
declare function u(value: void | { then: () => void }): number;
export const zeroArgs = u();
export const oneArg = u({ then: () => {} });

// Order inside the union does not matter.
declare function reversed(value: { then: () => void } | void): number;
export const reversedZero = reversed();

// Nested union, same rule.
declare function nested(value: (void | string) | number): number;
export const nestedZero = nested();

// A union with no void member keeps the parameter required.
declare function noVoid(value: string | undefined): number;
export const stillRequired = noVoid();

// And a trailing void-accepting parameter after a real one is still dropped,
// while the real one stays required.
declare function trailing(x: number, y: void | string): number;
export const trailingOk = trailing(1);
export const trailingBad = trailing();

// The parameter is optional, not absent: passing `undefined` where the union
// has no `undefined` member is still an error.
declare function strictVoid(value: void | number): number;
export const passUndefined = strictVoid(undefined);
