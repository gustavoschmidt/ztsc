// A decorator's `@ LeftHandSideExpression` must NOT swallow a following `[`.
// The bracket opens the decorated member's COMPUTED PROPERTY NAME, not an
// element access on the decorator expression — tsc suppresses the
// element-access production inside its decorator parsing context. Read the
// other way, `@f(x) [K.A]!: T` parsed as `f(x)[K.A]` derails the whole class
// body. Every member below must parse and check cleanly.
declare function deco(o: { note: string }): any;
declare const plain: any;

enum Field {
  Data = "data",
  Other = "other",
}

declare const key: unique symbol;

class C {
  @deco({ note: "qualified enum key" })
  [Field.Data]!: string;

  @plain
  [Field.Other]: number = 1;

  @plain
  [key]: boolean = true;

  @deco({ note: "method" })
  method(): void {}
}

declare const c: C;
const a: string = c[Field.Data];
const b: number = c[Field.Other];
