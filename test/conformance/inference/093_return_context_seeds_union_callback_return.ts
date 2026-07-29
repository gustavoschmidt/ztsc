// The contextual-return SEED (tsc's `InferencePriority.ReturnType` inference,
// which runs before the arguments are contextually typed) has to reach a type
// param that a callback parameter returns as one CONSTITUENT of a union, not
// only as its whole return type. `promiseTry`'s `fn: (…) => PromiseLike<T> | T`
// is that shape: without the seed `T` is still free while the arrow argument is
// checked, so the arrow's `return [a, b]` has no contextual type and widens to
// an array — and the call's `Promise<(number | string[])[]>` no longer matches
// the expected `Promise<void | readonly [number, string[]]>`.
export {};

declare const promiseTry: <TValue, TArgs extends unknown[]>(
  fn: (...args: TArgs) => PromiseLike<TValue> | TValue,
  ...args: TArgs
) => Promise<TValue>;

declare const index: number;
declare const faces: string[];

type Pair = readonly [number, string[]];

// async callback, contextual return type through the generic wrapper
const p1: Promise<void | Pair> = promiseTry(async () => {
  return [index, faces];
});

// the same with a try/catch whose catch arm falls through to `undefined`
const p2: Promise<void | Pair> = promiseTry(async () => {
  try {
    return [index, faces];
  } catch {
    return;
  }
});

// plain (non-async) callback
const p3: Promise<void | Pair> = promiseTry(() => {
  return [index, faces];
});

// the seed must not invent a type the arrow contradicts
const p4: Promise<void | Pair> = promiseTry(() => {
  return [faces, index]; // TS2322 (swapped: string[] where number is wanted)
});

// a literal discriminant survives the seed the same way
declare const pick: <T>(fn: () => T | PromiseLike<T>) => Promise<T>;
const p5: Promise<{ kind: "a"; n: number }> = pick(() => {
  return { kind: "a", n: index };
});
// a param that only appears WRAPPED in a constituent is not seeded from it:
// `flatMap`'s `U | readonly U[]` still infers U from the argument.
const flat: number[] = [1, 2, 3].flatMap((x) => [x, x * 2]);
const flatBad: string[] = [1, 2, 3].flatMap((x) => [x, x * 2]); // TS2322
