// tsc's `elaborateError` moves the blame off a mismatching callback argument
// and onto its returned expression for exactly one shape — its switch
// dispatches only on `SyntaxKind.ArrowFunction`, and `elaborateArrowFunction`
// then bails on a block body and on any annotated parameter. Everything else
// is the plain whole-argument TS2345.

declare function takesNumberFn(x: (n: number) => number): void;

// Concise arrow, unannotated parameter: TS2322 at the returned expression.
takesNumberFn((n) => "a");

// Annotated parameter: whole-argument TS2345.
takesNumberFn((n: number) => "b");

// Block body: whole-argument TS2345.
takesNumberFn((n) => {
  return "c";
});

// Function expression: whole-argument TS2345.
takesNumberFn(function (n) {
  return "d";
});

// The elaboration recurses through the returned object literal.
declare function takesObjFn(x: (n: number) => { a: number }): void;
takesObjFn((n) => ({ a: "e" }));
