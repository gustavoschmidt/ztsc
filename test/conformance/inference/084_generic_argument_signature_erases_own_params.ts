// A GENERIC function argument must not have its own type parameters bound to
// the parameters the call is still solving. tsc erases them to their base
// constraints (`getBaseSignature`) before inferring from the signature.
//
// Without the erasure, `postProcess`'s own `P` binds to `calculate`'s `T`,
// so the argument signature still mentions `T`; parameters are contravariant,
// that self-candidate outranks the covariant evidence from `prev`/`next`, and
// `T` never resolves — every argument then fails against an uninstantiated
// parameter.

interface Observed {
  tag: string;
}

declare function calculate<T extends Observed>(
  prev: T,
  next: T,
  postProcess?: (deleted: Partial<T>, inserted: Partial<T>) => [Partial<T>, Partial<T>],
): T;

declare function postProcess<P extends Observed>(
  deleted: Partial<P>,
  inserted: Partial<P>,
): [Partial<P>, Partial<P>];

export function run<S extends Observed>(prev: S, next: S) {
  // T resolves to S: the covariant evidence wins because the contravariant
  // candidate is now `Observed`, which S extends.
  const out = calculate(prev, next, postProcess);
  const same: S = out;
  return same;
}
