// Overload selection is speculative all the way through TYPE-ARGUMENT
// INFERENCE, not just through the argument check that follows it.
//
// Inferring a candidate's type arguments contextually types every function
// argument by that candidate's parameter, so a candidate whose parameter is not
// callable walks the arrow with no contextual signature and reports TS7006 on
// each of its parameters. Withdrawing only what the argument CHECK said left
// those standing: `select(selections: ReadonlyArray<SE>)`, tried before the
// callback overload beside it, made every kysely builder callback an implicit
// `any`. tsc runs the whole of `chooseOverload` with diagnostics off.
interface EB {
  col(k: string): string;
}
type CB = (eb: EB) => readonly string[];

// (a) The rejected candidate is rejected on the ARGUMENT CHECK: an array
// parameter is a perfectly good arity match, it just is not callable.
interface Over {
  sel<S extends string>(xs: ReadonlyArray<S>): S;
  sel<C extends CB>(cb: C): C;
}
declare const o: Over;
export const a1 = o.sel((eb) => [eb.col("x")]);

// (b) The rejected candidate is rejected on ARITY, which short-circuits before
// the argument check ever runs — so its inference is the only thing that ever
// spoke about the arrow.
interface Arity {
  join<K extends string>(t: string, k1: K, k2: K): K;
  join<C extends CB>(t: string, cb: C): C;
}
declare const j: Arity;
export const a2 = j.join("t", (eb) => [eb.col("x")]);

// (c) Control: a genuine error inside the arrow, under the candidate that WINS,
// still reports. Speculation withdraws the losers, not the winner.
export const a3 = o.sel((eb) => {
  const bad: number = "nope";
  return [eb.col("x")];
});

// (d) Control: an arrow with a truly uncontextual parameter is still TS7006 —
// no overload in the set gives it one.
declare function bare<T>(x: T): T;
export const a4 = bare((eb) => eb);
