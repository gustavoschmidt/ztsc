// A deferred conditional SOURCE against a UNION target that contains the
// matching conditional.
//
// `T[] | (M extends X ? T : T[])` is what a function that widens its own
// conditional return type declares. The relation had the branch-wise rule for a
// conditional target, but a union target fell through to "both branches must
// relate to the whole union" — and a branch generally relates only to its
// counterpart INSIDE the conditional member, so the call was rejected.

type F = { name: string };
type FH = F & { handle?: number };

// POSITIVE (must NOT error) --------------------------------------------------

declare function sink<M extends boolean | undefined>(
  v: FH[] | (M extends false | undefined ? FH : FH[]),
): void;
declare function src<M extends boolean | undefined>(): M extends
  | false
  | undefined
  ? F
  : F[];
export function pass<M extends boolean | undefined>() {
  sink<M>(src<M>());
}

// Identical conditional on both sides, target inside a union.
declare function sink2<M extends boolean>(
  v: string | (M extends true ? F : F[]),
): void;
declare function src2<M extends boolean>(): M extends true ? F : F[];
export function pass2<M extends boolean>() {
  sink2<M>(src2<M>());
}

// Regression: a conditional target (not in a union) still relates branch-wise.
declare function sink3<M extends boolean>(v: M extends true ? FH : FH[]): void;
export function pass3<M extends boolean>() {
  sink3<M>(src2<M>());
}

// Regression: a conditional source whose BOTH branches relate to the target
// still passes without any conditional member in the union.
declare function sink4(v: F | F[]): void;
export function pass4<M extends boolean>() {
  sink4(src2<M>());
}

// NEGATIVE (must error) ------------------------------------------------------

// A union member whose check/extends types differ is not a match, and neither
// branch relates to the union on its own.
declare function bad1<M extends boolean>(
  v: number | (M extends false ? F : F[]),
): void;
export function fail1<M extends boolean>() {
  bad1<M>(src2<M>()); // TS2345
}

// Matching conditional, but a branch does not relate.
declare function bad2<M extends boolean>(
  v: number | (M extends true ? { other: string } : F[]),
): void;
export function fail2<M extends boolean>() {
  bad2<M>(src2<M>()); // TS2345
}
