// tsc's `checkAndAggregateReturnExpressionTypes` gates the `never` answer on
// `!hasReturnWithNoExpression`: a bare `return;` produces `undefined` at
// runtime, so the function's inferred return type is `void` even though the
// body's statement list is terminal. Typed `never` it was assignable to every
// callback target and the mismatch went unreported.

declare function takesNumberFn(x: (n: number) => number): void;

takesNumberFn((n) => {
  return;
});

const bare1 = () => {
  return;
};
const bad1: 0 = bare1();

// A body that only throws still infers `never` for an arrow / function
// expression — no bare `return` in it.
const thrower1 = () => {
  throw 1;
};
const bad2: 0 = thrower1();

// …and a bare `return` alongside a value return unions in the `undefined`.
const mixed1 = (b: boolean) => {
  if (b) return 1;
  return;
};
const bad3: 0 = mixed1(true);
