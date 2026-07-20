// Negative control (sibling to 003_recursive_alias_relation_cap): a recursive
// alias whose BARE-REF argument GROWS on each hop must NOT be eagerly
// re-expanded. The shrinking-argument re-expansion (expandRef / aliasInstance)
// only fires on a STRICT DECREASE of the structural argument metric; here the
// check `[T] extends [{ stop: true }]` is always false and the false branch
// `GrowT<{ deeper: T }>` grows the argument, so the metric rises and ztsc keeps
// the lazy ref — a deterministic UNDER-REPORT (project under-report policy),
// never a false positive. tsc reports TS2589 here; the snapshot is deliberately
// empty (identical handling to 003). If the strict-decrease guard regresses to
// eager expansion, this input diverges (spurious errors or nontermination).
type GrowT<T> = [T] extends [{ stop: true }] ? T : GrowT<{ deeper: T }>;
declare const s: string;
const p: GrowT<{ a: number }> = s;
export {};
