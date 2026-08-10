// Which candidate an overload failure is reported against, and whether it is
// reported as TS2769 at all.
//
// tsc's `resolveCall` keeps two rejection piles. Only `candidatesForArgumentError`
// — the candidates whose ARITY fit and whose arguments did not — is re-checked
// with reporting on; a signature rejected on arity never joins it. The report
// then goes against the LAST member of that pile, so the anchor is that
// candidate's first bad argument. And when the pile holds exactly ONE
// candidate there is no overload set left to describe: tsc files that
// candidate's own applicability diagnostic (TS2345 / TS2353 / …) with no
// TS2769 wrapper at all.
//
// Every call below is spread over several lines so the reported line pins the
// anchor, and each group's last arity-valid candidate fails on a DIFFERENT
// argument from the first one's, so the two rules are distinguishable.

declare const s: string;
declare const n: number;
declare const b: boolean;

// Two candidates, failing on different arguments: the second one owns the
// report, so the anchor is argument 0.
declare function f1(a: string, b: string): void;
declare function f1(a: number, b: number): void;
f1(
  s,
  n,
);

// Three candidates.
declare function f3(a: string, b: string): void;
declare function f3(a: number, b: number): void;
declare function f3(a: boolean, b: boolean): void;
f3(
  s,
  n,
);

// Four candidates — same rule, no threshold.
declare function f4(a: string, b: string): void;
declare function f4(a: number, b: number): void;
declare function f4(a: boolean, b: boolean): void;
declare function f4(a: symbol, b: symbol): void;
f4(
  s,
  n,
);

// Two candidates that fail on the SAME argument still anchor there.
declare function f5(a: string, b: string): void;
declare function f5(a: string, b: number): void;
f5(
  s,
  b,
);

// Only ONE candidate has a fitting arity, so the zero-parameter overload never
// joins the pile: the report is the plain argument error, not TS2769, and it
// must not be taken from the zero-parameter signature (whose only complaint is
// an arity error nowhere near the argument at fault).
declare function f6(a: string): void;
declare function f6(): void;
f6(
  n,
);

export {};
