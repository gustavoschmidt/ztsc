// TS 4.3 split accessors: a get/set pair may declare DIFFERENT types. The
// property READS at the getter's return type and WRITES at the setter's
// parameter type (tsc's getWriteTypeOfSymbol). The DOM lib uses this for
// `Window.location` (reads `Location`, writes `string`).
interface Box {
  get p(): number;
  set p(v: string);
}
declare const b: Box;

// A write takes the setter's parameter type.
b.p = "ok";
// A read yields the getter's return type.
const r: number = b.p;
// A wrong write type still errors — against the SETTER's type.
b.p = 1;
// A wrong read type errors against the getter's.
const rbad: string = b.p;

// Element access writes the same way.
b["p"] = "ok";
b["p"] = 1;

// Inherited through `extends`.
interface Derived extends Box {
  other: number;
}
declare const d: Derived;
d.p = "ok";
d.p = 1;

// Class accessors, including through a base class and through `this`.
class CB {
  get q(): number {
    return 1;
  }
  set q(v: string) {}
  m() {
    this.q = "ok";
    this.q = 1;
  }
}
class CD extends CB {}
declare const cd: CD;
cd.q = "ok";
cd.q = 1;

// Generic interface: the setter's parameter is substituted with the
// reference's type arguments.
interface G<T> {
  get g(): number;
  set g(v: T);
}
declare const g: G<string>;
g.g = "ok";
g.g = 1;

// A set-only accessor still writes (and reads) at its parameter type.
interface SetOnly {
  set s(v: string);
}
declare const so: SetOnly;
so.s = "ok";
so.s = 1;
