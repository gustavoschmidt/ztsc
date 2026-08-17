// A decorator on a `this` parameter is TS1433, and tsc raises it from the
// PARSER rather than from the grammar pass. What follows, and what this case
// pins, is the report SITE: the parameter's FULL start — the offset just past
// the previous token, leading trivia included — so `m(a: C,    @dec this: C)`
// answers at the column right after the comma and not at the `@`.
//
// Being syntactic also means it silences every grammar diagnostic in the file
// behind it (`grammarErrorOnNode` gives up once the file has a parse error),
// which the CLI honours but this runner does not model — so no grammatical
// shape shares the file.
declare const dec: any;

class C {
  n = true;
  method(@dec this: C): boolean {
    return this.n;
  }
  spaced(a: number, @dec this: C): number {
    return a;
  }
}

function direct(@dec this: C): boolean {
  return this.n;
}

export { C, direct };
