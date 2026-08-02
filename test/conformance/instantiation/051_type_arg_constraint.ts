// TS2344 — a written type argument must satisfy its type parameter's
// constraint. The constraint is instantiated under the reference's OWN
// argument list, so `K`'s `keyof T & string` is decided against the supplied
// `C`, not against a free `T`.
//
// The check runs after every statement of every owned file (see
// `PendingTypeArgs`): enumerating a constraint's key set is only sound on a
// completely folded member table, and mid-materialization there is no such
// thing.
//
// The consequences of a bad argument are ALSO reported wherever the argument
// is USED — `pick` below is the same mistake, and it fails at the write.
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
