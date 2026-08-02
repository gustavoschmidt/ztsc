// Negatives for 039: the tuple-wrapped `[M] extends [string]` check must
// still take the FALSE branch where it genuinely should, so the fix that
// stopped it collapsing to `"no"` cannot have made it collapse to `"yes"`.
// Every annotation below is the branch NOT taken, so every line must error.

type Flat<M> = [M] extends [string] ? "yes" : "no";
type Outer<T> = T extends { k: infer M } ? ([M] extends [string] ? "yes" : "no") : never;

const f1: Flat<"a"> = "no"; // TS2322
const f2: Flat<number> = "yes"; // TS2322
const f3: Flat<string | number> = "yes"; // TS2322

const o1: Outer<{ k: "a" }> = "no"; // TS2322
const o2: Outer<{ k: string }> = "no"; // TS2322
const o3: Outer<{ k: number }> = "yes"; // TS2322
const o4: Outer<{ k: string | number }> = "yes"; // TS2322
const o5: Outer<{ k: "a" | "b" }> = "no"; // TS2322

// the enclosing conditional's own false branch still wins when it must
const o6: Outer<number> = 1; // TS2322 (`never`)

type Deep<T> = T extends { k: infer M }
  ? M extends unknown
    ? [M] extends [string]
      ? "yes"
      : "no"
    : never
  : never;
const d1: Deep<{ k: "a" }> = "no"; // TS2322
const d2: Deep<{ k: number }> = "yes"; // TS2322

type IsStr<M> = [M] extends [string] ? "yes" : "no";
type ViaAlias<T> = T extends { k: infer M } ? IsStr<M> : never;
const v1: ViaAlias<{ k: "a" }> = "no"; // TS2322
const v2: ViaAlias<{ k: number }> = "yes"; // TS2322
const v3: ViaAlias<{ k: string | number }> = "yes"; // TS2322
