// The `.d.ts` half of the `strictPropertyInitialization` ambient exemption:
// nothing in `lib.d.ts` is reported, and the `.ts` side still is — including a
// class that EXTENDS an ambient one (the base's constructor initializes the
// base's properties, never the derived class's).
import { Plain, Abstract, Shape } from "./lib";

export class Derived extends Plain {
  own: string;
  constructor() {
    super("x");
  }
}

export class Implements implements Shape {
  a: string;
}

export class Concrete extends Abstract {
  b: string;
  c: string;
  constructor() {
    super();
    this.b = "b";
  }
}

export const p: Plain = new Plain("x");
export const s: Shape = { a: p.a };
