// tsc's `getErrorSpanForNode` for the two function forms an argument can take.
//
// An ARROW errors from its own `pos` — the `async` modifier and the parameter
// list's `(` included — not from its first parameter; a named FUNCTION
// EXPRESSION errors on its NAME, not on the `function` keyword. Each case here
// puts the two candidates on different LINES so the snapshot can tell them
// apart.
declare function h(cb: (x: number) => void, n: number): void;
h(
  async (
    x: string
  ) => {},
  1
);

declare function m(f: (x: number) => string, n: number): void;
m(
  (
  ) => 1,
  2
);

declare function k(f: (x: number) => void): void;
k(function
  named(x: string) {});

// An unparenthesized single parameter already starts where tsc's span does.
declare function p(f: (x: number) => void): void;
p(
  x =>
    x.length
);
