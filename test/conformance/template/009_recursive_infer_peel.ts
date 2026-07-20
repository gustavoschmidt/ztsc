// Recursive template-literal `infer` peel with a SHRINKING string argument.
// `Tail<"a.b.c.d">` must fully reduce to `"d"` (not stall at the one-step
// `Tail<"b.c.d">` lazy ref), so a wrong assignment is caught against the fully
// reduced literal. Guards the shrinking-argument re-expansion added to
// expandRef / aliasInstance: the recursive `.ref` arm rebuilds a lazy ref, so
// without eager re-expansion the reduction stalls after one hop.
type Tail<P extends string> = P extends `${infer _K}.${infer R}` ? Tail<R> : P;
type Seg = Tail<"a.b.c.d">; // reduces to "d"
const ok: Seg = "d";
const w1: Seg = "c"; // TS2322
const w2: Seg = "a.b.c.d"; // TS2322
export {};
