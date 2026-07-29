// tsc's `getContextualThisParameterType`: a contextually typed function
// EXPRESSION whose own proto declares no `this` parameter takes `this` from the
// contextual signature's `this`. An arrow does not — it keeps the enclosing
// `this`. Only the body sees it; the type the expression HAS is still built
// from its own proto.
export {};

interface Host {
  n: number;
  xs: string[];
  run: (this: Host, k: number) => void;
  go: (this: Host) => number[];
}
declare const host: Host;

// assignment position
host.run = function (k) {
  const bad: string = this.n; // TS2322 (number -> string)
};

// declaration position
const a: Host["run"] = function (k) {
  const bad: string = this.n; // TS2322
};

// object-literal property position
const o: Host = {
  n: 1,
  xs: [],
  run: function (k) {
    const bad: string = this.n; // TS2322
  },
  go: function () {
    return this.xs.map((x) => x.length);
  },
};

// the contextual `this` has to be in place before the signature is built: an
// inner callback is contextually typed while the enclosing call infers its type
// arguments, which happens during signature construction, not during the body
// walk.
const g: Host["go"] = function () {
  return this.xs.map((x) => x.length);
};

// an own `this` parameter still wins over the contextual one
interface Other {
  m: string;
}
declare const other: Other;
const h: Host["run"] = function (this: Other, k) {
  const bad: number = this.m; // TS2322 (string -> number)
};

// an ARROW keeps the enclosing `this`, so the contextual one does not apply
class C {
  s = "s";
  make(): Host["run"] {
    return (k) => {
      const bad: number = this.s; // TS2322 (string -> number; `this` is C)
    };
  }
}
