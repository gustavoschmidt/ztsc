// `Pick<S, K>` with `K` an inference target takes its key set from ANY source,
// not just an object (tsc's `inferToMappedType`: `getIndexType(source)`).
//
// A FUNCTION source (an updater arrow with no return statement) and a UNION
// source (a forwarded `state` parameter) both have an empty key set, so
// `Pick<S, never>` is `{}` and the argument is trivially assignable. Leaving
// `K` unbound made it fall back to its `keyof S` constraint, so the target
// became the FULL state and rejected the update.

type S = { a: number; b: string };

interface Comp<P, T> {
  setState<K extends keyof T>(
    state:
      | ((prevState: Readonly<T>, props: Readonly<P>) => Pick<T, K> | T | null)
      | (Pick<T, K> | T | null),
    callback?: () => void,
  ): void;
}
declare const comp: Comp<unknown, S>;

// (a) an updater with no return statement
comp.setState(() => {});

// (b) a forwarded `state` parameter: K is re-inferred from the union
export const fwd: Comp<unknown, S>["setState"] = (state, cb) => {
  comp.setState(state, cb);
};

// (c) an object source still contributes its own keys
comp.setState({ a: 1 });

declare function pickKeys<K extends keyof S>(x: Pick<S, K>): [K];

// The inferred key set really is `never` for a function source.
export const fromFn: [never] = pickKeys(() => {});
// …and the literal keys for an object source.
export const fromObj: ["a"] = pickKeys({ a: 1 });
