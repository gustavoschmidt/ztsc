// TS2344 — a written type argument must satisfy its type parameter's
// constraint — is not implemented. See the DEFERRED entry: enumerating a
// constraint's key set is only sound on a member table ztsc folds
// completely, and it does not always fold one.
//
// The consequences of a bad argument are still reported wherever the
// argument is USED, which is what keeps a wrong instantiation from passing
// silently: `pick` below is the same mistake, and it fails at the write.
type Without<T, K extends keyof T & string> = [T, K];
interface C {
  a: number;
  b: number;
}
declare const x1: Without<C, "zz">;
declare const x2: Without<C, "a">;

type Plain<K extends "a" | "b"> = K;
declare const y1: Plain<"a">;
declare const y2: Plain<"zz">;

// The use site does report: `"zz"` is not a key of `C`.
declare function pick<T, K extends keyof T>(o: T, k: K): T[K];
declare const cc: C;
export const p1 = pick(cc, "a");
export const p2 = pick(cc, "zz");
