// An inherited abstract member counts as implemented when one of the extra
// base types the class picks up from its `interface` half declares it —
// tsc's "the class may have more than one base type via declaration merging
// with an interface with the same name" search. A base that only re-inherits
// the same still-abstract member does not count.
interface W {
  getSQL(): number;
}
declare abstract class Base {
  abstract getSQL(): number;
}
declare abstract class Mid extends Base {
  z: number;
}

// interface half extends `W`, which declares a concrete `getSQL`: satisfied.
interface D extends Mid, W {
}
declare class D extends Mid {
}

// interface half extends only `Mid`, whose `getSQL` is the abstract one.
interface E extends Mid {
}
declare class E extends Mid {
}

// no interface half at all.
declare class F extends Mid {
}

// interface half extends `W` without re-extending `Mid`: still satisfied.
interface G extends W {
}
declare class G extends Mid {
}

// The interface half DECLARES the member itself.
interface H {
  getSQL(): number;
}
declare class H extends Mid {
}
