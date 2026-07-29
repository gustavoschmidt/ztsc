// A rest parameter typed by a bare type PARAMETER (`...args: Args`) has no
// positional expansion on its own, so the parameter-type lookup answered the
// rest's array element type — nothing usable — and a function argument written
// for it got no contextual type at all, leaving its parameters implicit `any`.
//
// tsc expands the parameters of the INSTANTIATED signature, by which point
// `Args` is the tuple an earlier argument supplied.

type SetStateAction<V> = V | ((prev: V) => V);
interface WritableAtom<V, Args extends unknown[], R> {
  read: (v: V) => V;
  write: (...a: Args) => R;
}
type PrimitiveAtom<V> = WritableAtom<V, [SetStateAction<V>], void>;

declare const store: {
  set: <V, Args extends unknown[], R>(a: WritableAtom<V, Args, R>, ...args: Args) => R;
};
declare const atom: PrimitiveAtom<{ n: number }>;

// `s` is `{ n: number }`, so reading `.n` off it is fine.
export const r = store.set(atom, (s) => ({ n: s.n + 1 }));

// Two rest slots.
interface Two<V, Args extends unknown[]> {
  write: (...a: Args) => void;
}
declare const two: Two<number, [(p: number) => number, (q: string) => string]>;
declare function setTwo<V, Args extends unknown[]>(a: Two<V, Args>, ...args: Args): void;
setTwo(
  two,
  (p) => p + 1,
  (q) => q.length.toString(),
);
