// Negative for 085: a PRIMITIVE source's key set is its apparent type's
// members, which are not modelled here. Answering `never` for it would be
// wrong in a way that MATTERS — unlike the real key set, `never` satisfies
// `K extends keyof S`, so the bogus inference would silently accept the call.
// The constraint fallback has to stand instead.

type S = { a: number; b: string };

declare function pickKeys<K extends keyof S>(x: Pick<S, K> | null): void;

export function primitives() {
  pickKeys(123); // TS2345
  pickKeys("a"); // TS2345
  pickKeys(true); // TS2345
}
