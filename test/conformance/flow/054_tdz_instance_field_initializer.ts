// A NON-STATIC class field initializer runs at construction time, not at
// class-definition time, so a forward reference in it is not in the temporal
// dead zone. tsc puts it in the same clause as a nested function body
// (`isUsedInFunctionOrInstanceProperty`); ztsc's guard was the container test
// alone, and `containerOf` maps a field initializer back to the module scope,
// so every such forward reference reported TS2448.

export class Store {
  private snapshot = Snapshot.empty();
  read() {
    return this.snapshot;
  }
}

export class Snapshot {
  static empty() {
    return new Snapshot();
  }
}

// A block-scoped variable, same rule.
export class Holder {
  value = later;
}
const later = 1;

// A nested function inside the initializer is deferred twice over.
export class Lazy {
  make = () => new Snapshot();
}

// A STATIC field initializer DOES run at class-definition time, so it keeps
// the check. (Spelled with a block-scoped variable rather than a class: a
// forward CLASS reference is TS2449 in the oracle and TS2448 in ztsc, an
// unrelated code divergence.)
export class Eager {
  static shared = evenLater;
}
const evenLater = 2;

// The plain module-level forward reference is unaffected.
export const alsoEarly = later;

// And a method body, which was already exempt.
export class Methods {
  read() {
    return later;
  }
}
