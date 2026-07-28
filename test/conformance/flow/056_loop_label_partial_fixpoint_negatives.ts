// Negatives for the loop-label partial fixpoint: the partial union is the
// antecedent types gathered *so far*, so a back edge that widens the reference
// must still show up in the label's type. Answering a re-entrant query with
// the partial must not turn into "the entry type wins".
declare const rec: Record<string, string>;
declare const cond: boolean;

// The loop body assigns a second constituent: reads at the top of the body
// see both (tsc unions the entry edge with the back edge).
export const a = () => {
  let x: string | number = "a";
  while (cond) {
    const s: string = x; // error: string | number
    x = 1;
  }
  return x;
};

// The guard is inside the loop, so the back edge re-enters un-narrowed.
export const b = (x?: string) => {
  for (const k in rec) {
    const s: string = x; // error: string | undefined
    if (x === undefined) {
      x = k;
    }
  }
  return x;
};

// A self-reading assignment whose right-hand side widens: the label must not
// collapse to the entry type.
export const c = (x?: string) => {
  if (x === undefined) throw new Error("x");
  for (const k in rec) {
    const s: string = x; // error: string | undefined (back edge assigns undefined)
    x = cond ? x.replace("a", k) : undefined;
  }
  return x;
};

// The narrowing is invalidated by an unrelated write to the same variable
// deeper in the loop.
export const d = (x?: string) => {
  if (x === undefined) throw new Error("x");
  for (const k in rec) {
    for (const j in rec) {
      const s: string = x; // error: string | undefined
      x = cond ? j : undefined;
    }
  }
  return x;
};
