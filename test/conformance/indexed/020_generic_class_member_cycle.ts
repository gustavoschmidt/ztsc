// The generic form of 019: the cycle runs through a generic class, so the
// single member has to be instantiated with the ref's own arguments before it
// is handed back. `G<T>["v"]` inside the alias must stay the type parameter
// (and become `string` once the alias is instantiated), never `any`.
type GAlias<T> = { a: G<T>["v"]; b: G<T>["n"] };

class G<T> {
  v: T;
  n: number = 1;
  constructor(v: T) {
    this.v = v;
  }
  m(o: GAlias<T>) {
    return o.a;
  }
}

declare const ga: GAlias<string>;

const gok1: string = ga.a;
const gok2: number = ga.b;

const gbad1: number = ga.a; // TS2322
const gbad2: string = ga.b; // TS2322

// An INHERITED member reached through the same cycle: the lazy lookup misses
// in `H`'s own member table and has to walk `extends`.
type HAlias = { c: H["base"]; d: H["own"] };

class Thing2 {
  w: number = 1;
}
class Base {
  base: Thing2 = new Thing2();
}
class H extends Base {
  own: string = "";
  use(h: HAlias) {
    return h.d;
  }
}

declare const ha: HAlias;
const hok1: Thing2 = ha.c;
const hbad1: string = ha.c; // TS2322
