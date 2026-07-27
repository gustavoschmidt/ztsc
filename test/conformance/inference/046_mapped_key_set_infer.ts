// Inference INTO a non-homomorphic mapped type whose key constraint is itself a
// type parameter being inferred — tsc's `inferToMappedType` TypeParameter
// branch: "inferring from S to `{ [P in K]: X }` where K is a type parameter"
// first infers `keyof S` to K. This is the `Pick<S, K>` shape.
//
// It is what makes React's `setState` work: `setState<K extends keyof S>(state:
// Pick<S, K> | S | null)` recovers `K` from the argument's own keys. Without it
// `K` stayed unbound, fell back to its `keyof S` constraint, and
// `Pick<S, keyof S>` — the whole state — rejected every partial update.
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
  one() {
    this.setState({ a: "x" });
  }
  two() {
    this.setState({ b: 1, c: true });
  }
  whole() {
    this.setState({ a: "x", b: 1, c: true });
  }
  updater() {
    this.setState((prev) => ({ a: prev.a }));
  }
  updaterTwo() {
    this.setState((prev, props) => ({ b: prev.b + props.title.length }));
  }
}

// The key set is read straight off the argument, so it survives being narrower
// than the constraint. (`K` is checked through the return type rather than
// through a rejected call, so the case does not depend on which code the
// argument-mismatch elaboration picks.)
declare function pick<T, K extends keyof T>(t: T, shape: Pick<T, K>): K;
const k = pick({ a: 1, b: "s", c: true }, { b: "t" });
const okK: "b" = k;
const badK: "a" = k;
const two = pick({ a: 1, b: "s", c: true }, { a: 2, c: false });
const okTwo: "a" | "c" = two;
const badTwo: "a" = two;
// The whole-object form infers the full key set, not a subset.
const all = pick({ a: 1, b: "s" }, { a: 2, b: "t" });
const okAll: "a" | "b" = all;

export { C };
