// `fixTypeArgs` left a LIBRARY (`.d.ts`) generic's complex type-parameter
// DEFAULT unsubstituted, so a bare `Queue` kept `NameType` spelled as a
// conditional over `Queue`'s OWN type parameters — a term nothing downstream
// can ever close. `queue.add(name, data)` was then TS2345 against
// `DataTypeOrJob extends Job<any, any, infer N> ? infer N : DefaultNameType`.
//
// The leniency exists because threading an ABSTRACT argument through a
// library default can re-materialize deeply recursive `.d.ts` machinery, so
// it is kept exactly where that is possible: the substitution now runs only
// when every already-resolved position is GROUND, which is a finite rewrite
// of a finite term. bullmq's `Queue` is the shape.

import { Holder, Job, Queue } from "./queue.js";

declare const q: Queue;

export function bareQueue() {
  q.add("some-name", { a: 1 });
}

// Explicit arguments were always fine — kept as the reference point.
declare const q2: Queue<any, string, any, string>;
export function explicitArgs() {
  q2.add("some-name", { a: 1 });
}

// A concrete first argument resolves the defaults through it.
declare const q3: Queue<Job<number, string, "blue">>;
export function concreteJob() {
  q3.add("blue", 1);
}

// Negative control: the same reference still rejects a wrong name.
export function wrongName() {
  q3.add("red", 1);
}

// Negative control: the same reference still rejects wrong data.
export function wrongData() {
  q3.add("blue", "not-a-number");
}

// Negative control: a default over an ABSTRACT earlier position keeps the
// lenient path, so nothing about `Holder` moves.
export function holder<T>(h: Holder<T>) {
  h.take(1);
}
