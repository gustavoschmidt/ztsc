// The EMPTY object argument is an informative inference into `{ [P in K]: X }`,
// not a miss: `K` is `never`, so `Pick<S, never>` is `{}` and the call is legal.
// Treating it as "nothing to infer" left `K` to its `keyof S` constraint, which
// made the target the whole state and rejected `setState({})` with every
// property reported missing.
type S = { a: string; b: number; c: boolean };
type P = { title: string };

declare class Comp<PP, SS> {
  props: Readonly<PP>;
  state: Readonly<SS>;
  setState<K extends keyof SS>(
    state:
      | ((prevState: Readonly<SS>, props: Readonly<PP>) => Pick<SS, K> | SS | null)
      | (Pick<SS, K> | SS | null),
    callback?: () => void,
  ): void;
}

class C extends Comp<P, S> {
  empty() {
    this.setState({});
  }
  emptyUpdater() {
    this.setState(() => ({}));
  }
  // A non-empty argument still infers its own keys.
  one() {
    this.setState({ a: "x" });
  }
}

// `K` inferred as `never` is observable through the return type: nothing but
// `never` is assignable back into a `never`-typed binding.
declare function pick<T, K extends keyof T>(t: T, shape: Pick<T, K>): K;
const k = pick({ a: 1, b: "s" }, {});
const okNever: never = k;

// A NON-empty argument must not collapse to `never` — it infers exactly its own
// keys, so neither the `never` binding nor a wrong key accepts it.
const one = pick({ a: 1, b: "s" }, { a: 2 });
const okOne: "a" = one;
const badNotNever: never = one;
const badOne: "b" = one;
