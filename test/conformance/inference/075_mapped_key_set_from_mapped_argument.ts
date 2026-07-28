// A deferred MAPPED argument carries its own key set: forwarding an already
// `MyPick<S, K2>`-typed value into a `MyPick<S, K>` parameter must infer
// `K = K2`, not leave `K` at its `keyof S` constraint (which is the whole
// object, and rejects the partial).
type MyPick<T, K extends keyof T> = { [P in K]: T[P] };

declare class Comp<S> {
  setState<K extends keyof S>(
    state: ((prev: S) => MyPick<S, K> | S | null) | MyPick<S, K> | S | null,
  ): void;
}
type St = { a: number; b: number; c: string };
declare const comp: Comp<St>;

export const forward = <K extends keyof St>(state: MyPick<St, K> | St | null) => {
  comp.setState(state);
};

// a plain generic pass-through of the key set
declare function take<T, K extends keyof T>(o: T, p: MyPick<T, K>): K;
declare const st: St;
export const pass = <K2 extends keyof St>(p: MyPick<St, K2>) => {
  const got = take(st, p);
  const back: K2 = got;
  void back;
};

// an object argument still infers its literal keys
const lit = take(st, { a: 1 });
const litK: "a" = lit;
void litK;

// the key set really is the ARGUMENT's, not the parameter's constraint
declare const p2: MyPick<St, "a">;
const narrow: "b" = take(st, p2); // TS2322
void narrow;
