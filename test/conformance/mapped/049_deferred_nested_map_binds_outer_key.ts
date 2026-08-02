// Substitution counterpart of 048: when the outer map materializes, the outer
// key must be pushed into a nested map that is still DEFERRED.
//
// `substMappedKey` was gated on `containsMappedParam`, which reads only a
// deferred map's KEY SET (constraint / homomorphic source) — deliberately, since
// the value/`as` always mention the map's OWN key and reading them would drag
// the substitution through every deferred map. But a map deferred on a free type
// parameter, whose only mention of the ENCLOSING key is in its value, then
// answered "no mapped param here" and was returned untouched: the outer key
// survived as a bare `P` in the result. The gate is now an exact-id test
// (`mentionsMappedParam`), so the value/`as` can be walked without the false
// positive, while a map that BINDS the same id (a recursive alias re-entering
// the same mapped node) still shadows it.

// Outer key set concrete -> materializes immediately; inner key set generic in
// `T` -> still deferred at that moment. `P` must nonetheless be bound.
type Val<T> = { [P in "a" | "b"]: { [M in keyof T]: [P, M] } };
declare const v: Val<{ q: 1; r: 2 }>;
const v1: ["a", "q"] = v.a.q;
const v2: ["b", "r"] = v.b.r;
const v3: ["b", "r"] = v.a.q; // TS2322 — `P` was substituted per outer key

// Same, with the enclosing key inside the deferred map's `as` clause.
type As<T> = {
  [P in "a" | "b"]: { [M in keyof T as `${P & string}${M & string}`]: M };
};
declare const w: As<{ q: 1; r: 2 }>;
const w1: "q" = w.a.aq;
const w2: "r" = w.b.br;
const w3: "q" = w.a.br; // TS2339 — remapped names really are per-outer-key

// A recursive alias re-enters the SAME mapped node, so the inner instance
// carries the same key id: its own binder wins and nothing inside is rewritten.
type Deep<T> = { [K in keyof T]: T[K] extends object ? Deep<T[K]> : [K, T[K]] };
declare const d: Deep<{ a: { b: { c: number } }; z: string }>;
const d1: ["c", number] = d.a.b.c;
const d2: ["z", string] = d.z;
const d3: ["c", number] = d.z; // TS2322

// A signature's own type parameter shadows a same-named enclosing mapped key,
// while a differently named enclosing key stays visible to that signature.
type Meth<S> = {
  [P in keyof S]: { [M in keyof S]: { f<P2>(x: P2): [P, M, P2] } };
};
declare const m: Meth<{ a: 1; b: 2 }>;
const m1: ["a", "b", number] = m.a.b.f(1);
const m2: ["a", "b", string] = m.a.b.f(1); // TS2322
