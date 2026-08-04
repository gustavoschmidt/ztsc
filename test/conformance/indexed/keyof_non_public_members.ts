// `keyof` skips `private` and `protected` class members (tsc's
// `getLiteralTypeFromProperty` answers `never` for a non-public property), so
// every mapped type built on `keyof C` — `Pick<C, keyof C>` above all — sees
// only the public surface. A `constructor(private db: …)` parameter property
// counts as non-public too, which is how immich's repository mocks are typed:
// `RepositoryInterface<T> = Pick<T, keyof T>` over classes that hold their
// database handle that way.

class C {
  constructor(
    private db: number,
    protected shared: string,
    public exposed: boolean,
    plain: number,
  ) {
    this.secret = plain;
  }
  private secret: number;
  protected guarded = 2;
  public open = 3;
  bare = 4;
  private hiddenMethod(): number {
    return this.db;
  }
  method(x: string): number {
    return x.length + this.guarded + this.secret;
  }
}

type K = keyof C;
const k1: K = 'open';
const k2: K = 'method';
const k3: K = 'exposed';
const k4: K = 'bare';
const k5: K = 'db'; // TS2322
const k6: K = 'secret'; // TS2322
const k7: K = 'guarded'; // TS2322
const k8: K = 'hiddenMethod'; // TS2322

// A mapped type over the class keeps only the public members: the non-public
// ones are not keys, so they are not required of a value of the mapped type.
type Mapped = { [P in keyof C]: C[P] };
const m: Mapped = {
  exposed: true,
  open: 3,
  bare: 4,
  method: (x: string) => x.length,
};

// Interfaces and object literal types have no visibility, so nothing changes.
interface I {
  a: number;
  b: string;
}
type KI = keyof I;
const ki1: KI = 'a';
const ki2: KI = 'c'; // TS2322

// Static side.
class S {
  private static hidden = 1;
  protected static guarded = 2;
  static shown = 3;
}
type KS = keyof typeof S;
const s1: KS = 'shown';
const s2: KS = 'hidden'; // TS2322
const s3: KS = 'guarded'; // TS2322

// A subclass sees a protected member of its base, but `keyof` still excludes
// it — visibility is a property of the declaration, not of the vantage point.
class D extends C {
  read(): number {
    return this.guarded;
  }
}
type KD = keyof D;
const d1: KD = 'read';
const d2: KD = 'guarded'; // TS2322
