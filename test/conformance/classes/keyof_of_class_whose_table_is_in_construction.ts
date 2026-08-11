// `keyof C` demanded from INSIDE C's own member-table materialization must
// still be C's whole key set.
//
// `Model` and `Store<T extends Model>` are mutually recursive, and `helper`
// has an INFERRED type — so checking its initializer runs inside `Model`'s
// member-table window, and reaching `Store<Model>["pick"]` from there
// substitutes `keyof T` and asks for `keyof` of the very class being built.
//
// Member NAMES are a function of the declarations, so the answer must not
// depend on that. When it did, `keyof Model` came back unresolvable from
// inside the cycle, the collapse was memoized under `Store<Model>`, and every
// later `pick` — including the ones outside the cycle — rejected a perfectly
// good key. Which asker got there first decided the answer, so the diagnostic
// set moved with the file partition.

abstract class Model {
  id!: string;
  isNew!: boolean;
  store!: Store<Model>;
  helper = () => this.store.pick("isNew");
}

abstract class Store<T extends Model> {
  pick = (k: keyof T): void => {
    void k;
  };
}

declare const s: Store<Model>;

// A declared key of `Model`, demanded after the cycle has closed.
s.pick("isNew");
s.pick("store");

// Not a key of `Model`, rejected either way.
s.pick("nope");
