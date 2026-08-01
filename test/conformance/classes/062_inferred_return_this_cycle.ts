// Termination pin for the lazy single-member lookup in expression position
// (see 061). A member whose inferred type is reached FROM ITS OWN body is a
// genuine circularity, and the lazy lookup has to cut it rather than recur:
// `lazyRefProp` marks the member symbol it is resolving and answers "not a
// member" for one already on that stack, so each shape below falls back to the
// ordinary not-found path after at most one pass per member.
//
// The cut is named, not silent: `memberTypeOf` sees a member re-enter its own
// resolution and reports the circle tsc reports — TS7023 for an inferred
// return type, TS7022 for an inferred field type — beside TS2729 for a field
// read before its initialization. The case still pins the CUT — without it
// these hang — and the non-circular members in the same file prove the
// lookup itself still resolves.
declare function use(x: unknown): void;

// Direct self-reference through a call.
class Direct {
  m() {
    return this.m();
  }
}

// Mutual recursion between two inferred returns.
class Mutual {
  a() {
    return this.b();
  }
  b() {
    return this.a();
  }
}

// A field initializer that reads itself.
class SelfField {
  p = this.p;
}

// A field initializer that reads a LATER sibling: not circular as a type, but
// the read happens before the sibling is initialized.
class Forward {
  f = this.g;
  g = 1;
}

// An annotation breaks the cycle: the return type is known without the body.
class Annotated {
  x = 1;
  m(): number {
    return this.m();
  }
  ok() {
    return this.x;
  }
}

// Proof the non-circular member still resolves to its real type.
const bad: string = new Annotated().ok();
use(bad);

export { Direct, Mutual, SelfField, Forward, Annotated };
