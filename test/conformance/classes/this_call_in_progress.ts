// A method with an INFERRED return type has its body checked while the
// class's member table is still being built, so `resolveStructural` on the
// receiver can only answer the error type and a call on it used to degrade to
// `any`. The declarations settle it instead: a class body has no
// call-signature syntax (`classes.inProgressCallSigless`).

class D1 {
  m() {
    return this();
  }
}

// The annotated form — same call, table not held open — always reported.
class D2 {
  m(): void {
    return this();
  }
}

// A declaration-merged `interface` half CAN supply a call signature, and then
// neither form is an error.
class E1 {
  m() {
    return this();
  }
  n(): number {
    return this();
  }
}
interface E1 {
  (): number;
}

// …including one inherited by that half.
interface CallableBase {
  (): number;
}
class E2 {
  m() {
    return this();
  }
}
interface E2 extends CallableBase {}

// `implements` does NOT give a class a call signature, so this stays an error
// (the unimplemented signature is its own diagnostic).
interface FBase {
  (): string;
}
class F1 implements FBase {
  m() {
    return this();
  }
}
