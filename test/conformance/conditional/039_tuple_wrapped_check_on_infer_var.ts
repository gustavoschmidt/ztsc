// `[M] extends [string]` — the standard idiom for turning a conditional's
// distributivity OFF — must not change WHICH branch is taken when `M` is a
// type parameter inferred by an ENCLOSING conditional.
//
// ztsc used to resolve the inner conditional at BUILD time: the check `[M]`
// is a tuple, and `containsFreeTypeParam` doesn't count `infer` vars, so the
// conditional looked fully concrete. `[M]` with an unbound `M` relates to
// nothing, so the FALSE branch got baked into the enclosing conditional's
// true branch and no later instantiation could undo it. Every case below
// answered "no".

// --- flat, no enclosing conditional (regression guard: this always worked)
type Flat<M> = [M] extends [string] ? "yes" : "no";
const f1: Flat<"a"> = "yes";
const f2: Flat<string> = "yes";
const f3: Flat<number> = "no";
// tuple wrapping disables distribution, so a mixed union is NOT a string
const f4: Flat<string | number> = "no";
const f5: Flat<"a" | "b"> = "yes";

// --- one conditional deep: M comes from `infer` in the enclosing check
type Outer<T> = T extends { k: infer M } ? ([M] extends [string] ? "yes" : "no") : never;
const o1: Outer<{ k: "a" }> = "yes";
const o2: Outer<{ k: string }> = "yes";
const o3: Outer<{ k: number }> = "no";
// distributivity is still off through the nesting
const o4: Outer<{ k: string | number }> = "no";
const o5: Outer<{ k: "a" | "b" }> = "yes";
// `[never]` is a one-element tuple, not `never`, so the true branch holds
const o6: Outer<{ k: never }> = "yes";

// --- two conditionals deep
type Deep<T> = T extends { k: infer M }
  ? M extends unknown
    ? [M] extends [string]
      ? "yes"
      : "no"
    : never
  : never;
const d1: Deep<{ k: "a" }> = "yes";
const d2: Deep<{ k: number }> = "no";

// --- the same shape spelled with a type alias in between, so the inner
// conditional is reached through an instantiation rather than inline
type IsStr<M> = [M] extends [string] ? "yes" : "no";
type ViaAlias<T> = T extends { k: infer M } ? IsStr<M> : never;
const v1: ViaAlias<{ k: "a" }> = "yes";
const v2: ViaAlias<{ k: number }> = "no";
const v3: ViaAlias<{ k: string | number }> = "no";

// --- infer var reached through a mapped type over the enclosing conditional
type MapStr<T> = T extends { k: infer M } ? { [P in "p"]: [M] extends [string] ? "yes" : "no" } : never;
const m1: MapStr<{ k: "a" }> = { p: "yes" };
const m2: MapStr<{ k: number }> = { p: "no" };

// --- still deferred while M is a genuinely free type parameter
function keep<M>(x: Flat<M>): Flat<M> {
  return x;
}
const k1: Flat<string> = keep<string>("yes");
