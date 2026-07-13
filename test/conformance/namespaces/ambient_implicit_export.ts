// In an ambient (`declare`) namespace, members are implicitly exported and
// visible as `N.member` without an explicit `export` keyword.
declare namespace A {
  const x: number;
  function f(p: string): boolean;
  interface Opts {
    verbose: boolean;
  }
}
const a: number = A.x;
const b: boolean = A.f("h");
const o: A.Opts = { verbose: true };
const bad: string = A.x;
