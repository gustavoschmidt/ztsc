// A method (or arrow field) with an INFERRED return type that reads
// `this.<member>`.
//
// Such a method's return type is computed by checking its body, and that
// happens while the class's instance type is still being materialized — the
// member table is open, so resolving the whole `this` type could only answer
// `error` there, i.e. `any`. That `any` was then memoized into the method's
// signature, so it was not a transient: every later `c.m()` anywhere in the
// program saw `any` too, and every callback whose contextual type came through
// such a receiver lost its parameter types (implicit-`any`).
//
// The single member can be resolved on its own without the table (the same
// lazy lookup the `C["m"]` type position already used), so all the inferred
// types below are real and the mismatches are the only diagnostics.
declare function use(x: unknown): void;

class C {
  n = 1;
  label = "x";
  opt?: number;

  // Inferred: number.
  readField() {
    return this.n;
  }

  // Inferred through a SIBLING method's inferred return: string.
  chain() {
    return this.mid();
  }
  mid() {
    return this.label;
  }

  // Inferred: number | undefined (the member is optional).
  readOptional() {
    return this.opt;
  }

  // An arrow field's inferred return goes through the same path.
  arrow = () => this.n;

  // A getter's inferred type, read back through the instance.
  get viaGetter() {
    return this.label;
  }

  // Contextual typing survives: `v` is `number`, not an implicit `any`.
  callback() {
    return this.run((v) => v);
  }
  run(cb: (v: number) => number): number {
    return cb(this.n);
  }

  // Controls that must not change.
  annotated(): number {
    return this.n;
  }
  self() {
    return this;
  }
  static s = 2;
  static readStatic() {
    return C.s;
  }
}

declare const c: C;

// Proof the inferred types are real, not `any`: each of these must error.
const a: string = c.readField();
const b: number = c.chain();
const d: number = c.readOptional();
const e: string = c.arrow();
const f: number = c.viaGetter;
const g: string = c.callback();
const h: string = c.annotated();
const i: string = C.readStatic();
const j: string = c.self().n;

// ... and these must not.
const ok1: number = c.readField();
const ok2: string = c.chain();
const ok3: C = c.self();

use([a, b, d, e, f, g, h, i, j, ok1, ok2, ok3]);

// Inheritance: an inferred return that reads a BASE member.
class Base {
  bn = 1;
}
class Derived extends Base {
  readBase() {
    return this.bn;
  }
}
const k: string = new Derived().readBase();
use(k);

// Generic class: the member type comes back instantiated, not generic.
class Box<T> {
  constructor(public value: T) {}
  read() {
    return this.value;
  }
}
const m: string = new Box(1).read();
use(m);

export { C, Derived, Box };
