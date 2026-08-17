// Legacy (`experimentalDecorators`) decorators reject three shapes the
// standard dialect accepts, and this case pins all three:
//
//   1. a class EXPRESSION, and every member of one — `nodeCanBeDecorated`
//      asks for `isClassDeclaration(parent)`, not `isClassLike(parent)`;
//   2. a `#private` member name, whatever the member is;
//   3. the SECOND of a get/set pair whose first already carries modifiers
//      (TS1207).
//
// It also pins the rule that holds in both dialects: a member whose modifier
// list already answered never also reports the TS116x its computed name would
// earn — `checkGrammarModifiers` short-circuits `checkGrammarProperty`, so
// `@dec [foo()]: any` inside a class expression is TS1206 alone where the
// undecorated `[foo()]: any` beside it is TS1166.
declare function dec(...args: any[]): any;
declare function foo(): string;

class Decl {
  [foo()]: any;
  @dec [foo()]: any;
  @dec #priv = 1;
  @dec #privMethod(): void {}
}

const Expr = class {
  [foo()]: any;
  @dec [foo()]: any;
  @dec plain: any;
  @dec run(): void {}
  @dec get g(): number {
    return 1;
  }
};

const Decorated = @dec class {};

class Pair {
  @dec get both(): number {
    return 1;
  }
  @dec set both(v: number) {}

  static get sBoth(): number {
    return 1;
  }
  @dec static set sBoth(v: number) {}
}

export { Decl, Expr, Decorated, Pair };
