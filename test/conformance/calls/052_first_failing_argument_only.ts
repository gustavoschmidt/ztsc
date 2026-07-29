// tsc reports at most ONE argument error per call.
// `checkApplicableSignature` walks the arguments in order and returns as soon
// as one fails, so the arguments after it are never related to their
// parameters at all — and with a generic signature they could not be judged
// fairly anyway, since the failing argument is often what mis-inferred the
// type argument the rest are checked against.
declare function two(a: number, b: string): void;
export const t = () => {
  // ONE error, on `"x"`, even though `1` is wrong for `b` as well.
  two("x", 1);
};

// The rule is positional, not "the leftmost wrong-looking one": a correct
// first argument still lets the second be reported.
export const u = () => {
  two(1, 2);
};

// Generic: the bad first argument decides `T`, and the second argument is not
// reported against the type that inference then settled on.
declare function pair<T>(a: T, b: T): T;
export const v = () => {
  const s: string = pair("a", "b");
  return s;
};

// A whole-argument-list mismatch on a generic call is still one error.
declare function box<T extends { id: string }>(a: T, b: T, c: T): T;
export const w = () => {
  box({ id: 1 }, { id: 2 }, { id: 3 });
};

// Excess-property errors on later arguments are suppressed the same way: the
// first failure ends the walk.
declare function opts(a: number, b: { known: boolean }): void;
export const x = () => {
  opts("nope", { known: true, extra: 1 });
};

// Control for the line above: with a valid first argument the excess property
// on the second IS reported.
export const y = () => {
  opts(1, { known: true, extra: 1 });
};
