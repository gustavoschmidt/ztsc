// An EMPTY array literal argument is contextually typed by the parameter,
// whose element type is the very type parameter the call is inferring. Using
// that back as evidence infers `T` for `T` and leaks a naked type parameter
// into the result; tsc reads no contextual element type for an empty literal
// at all, so the candidate is `never`.

declare function mk<T>(xs: T[]): Set<T>;
declare function two<T>(v: string | undefined, xs: T[]): Set<T>;

enum Worker {
  Api = "api",
  Micro = "micro",
}

declare function setDifference<T>(a: Set<T>, ...rest: Set<T>[]): Set<T>;
declare function asSet<T>(value: string | undefined, defaults: T[]): Set<T>;

const included = asSet(undefined as string | undefined, [Worker.Api, Worker.Micro]);
const excluded = asSet(undefined as string | undefined, []);
const workers: Worker[] = [...setDifference(included, excluded)];

// `never` is the element candidate, so the result is `Set<never>` — which is
// assignable to every `Set<…>` and to `unknown`, and never leaks a `T`.
const a: Set<never> = mk([]);
const b: Set<never> = two("x", []);

// A non-empty literal is unaffected.
const c: Set<number> = mk([1]);
// So is an already-typed empty array.
const nv: never[] = [];
const d: Set<never> = mk(nv);

export { workers, a, b, c, d };
