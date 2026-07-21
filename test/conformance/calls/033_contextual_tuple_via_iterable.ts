// An array literal returned from a `.map` callback is formed as a TUPLE when
// the outer generic call supplies a tuple contextual type through an
// `Iterable<readonly [K, V]>` parameter (`new Map(...)`). Two hops:
//   1. `unify` relates the callback's `U[]` return to an iterable-shaped
//      contextual type by its iteration element (Array vs Iterable member
//      inference), so `U` is seeded with `readonly [K, V]` and the callback
//      body sees a tuple context — including through a nullable union
//      (`Iterable<...> | null`) and during overload-candidate probing.
//   2. the nested generic call argument is contextually typed by the
//      still-uninstantiated parameter, so the outer `K`/`V` infer from the
//      resulting `[string, number][]` instead of collapsing to `unknown`.

const rows: { id: string; n: number }[] = [];

// Inferred K,V through the (overloaded, nullable-iterable) Map constructor.
const m1 = new Map(rows.map((r) => [r.id, r.n]));
const ok1: Map<string, number> = m1; // ok: m1 is Map<string, number>

// Explicit type arguments still need the tuple to form.
const m2 = new Map<string, number>(rows.map((r) => [r.id, r.n])); // ok

// Single-signature nullable-iterable parameter.
declare function mk<K, V>(e: Iterable<readonly [K, V]> | null): Map<K, V>;
const m3 = mk(rows.map((r) => [r.id, r.n]));
const ok3: Map<string, number> = m3; // ok

// A plain `Iterable<readonly [A, B]>` parameter (no union, no overload).
declare function takesIter(x: Iterable<readonly [string, number]>): void;
takesIter(rows.map((r) => [r.id, r.n])); // ok

// Negative control: no tuple context — the array literal widens to
// `(string | number)[]`, which is not assignable to a tuple.
const widened = [rows[0].id, rows[0].n];
const bad1: [string, number] = widened; // error: (string|number)[] not a tuple

// Negative control: a wrong literal element under a tuple context.
const bad2: [string, number] = ["a", "b"]; // error: "b" not assignable to number

// Negative control: a genuine key/value mismatch still fails against an
// annotated target (the entries produce string keys).
const bad3: Map<number, number> = new Map(rows.map((r) => [r.id, r.n])); // error

// Negative control: passing a non-tuple array to the entries parameter — the
// element is `number`, not a `[K, V]` pair.
const nums: number[] = [1, 2, 3];
const bad4 = new Map(nums); // error: number is not a readonly [K, V]
