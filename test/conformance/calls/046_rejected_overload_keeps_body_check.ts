// A rejected overload candidate contextually types a function-expression
// argument and WALKS ITS BODY, filing the body's diagnostics. Withdrawing them
// on rejection used to drop the list entries while keeping their dedupe keys,
// so the winning candidate's re-walk of the same body was silently swallowed
// and the whole body read as if it had never been checked.
declare function f(cb: (a: number) => number, seed: number): number;
declare function f(cb: (a: string) => string, seed: string): string;

// The FIRST candidate is rejected (a string seed), so the body below is walked
// twice: once for the losing candidate and once for the winning one.
export const x = f((a: string) => {
  const bad: number = "not a number";
  return a + bad;
}, "s");

// Control: the first candidate wins outright, so the body is walked once.
export const y = f((a: number) => {
  const alsoBad: number = "nope";
  return a + alsoBad;
}, 1);
