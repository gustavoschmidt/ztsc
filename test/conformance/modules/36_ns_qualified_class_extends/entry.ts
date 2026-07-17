import * as m from "./shapes";
// Namespace-qualified base with type arguments in `extends`, and a
// namespace-qualified `implements`.
class Derived extends m.Base<number> implements m.Named {
  name: string = "d";
  doubled(): number { return this.value * 2; }
}
const d = new Derived();
const n: number = d.value;
const w: number = d.wrap(5);
// Proves the base was instantiated with <number>: passing a string is the
// sole error (regression: the base resolved to nothing, so `wrap` was absent).
const bad: number = d.wrap("x");
