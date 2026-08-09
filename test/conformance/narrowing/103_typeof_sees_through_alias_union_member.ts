// tsc's unions are always FLATTENED, so `typeof x === "string"` sees every
// primitive constituent however the union was spelled. ztsc's can hold a
// reference to an alias that is itself a union — a naked type variable
// inferred from an alias-typed argument is where that happens — and the
// whole reference then answered "not a string", collapsing the guarded
// branch to `never`.
//
// React's `Children.map(children, child => …)` is the shape: its
// `children: C | readonly C[]` parameter infers `C` from a `ReactNode`
// argument, and `if (typeof child !== "string") return` left the string
// branch empty, so `child.match(…)` was a false TS2339.

type Leaf = { el: true };
type Node1 = Leaf | string | number;
type Nested = Node1 | null | undefined;

// Inferred through a naked type variable, exactly as `Children.map` does.
declare function each<C, T>(
  children: C | readonly C[],
  fn: (child: C) => T,
): T[];

declare const nodes: Nested;

export const lengths = each(nodes, child => {
  if (typeof child !== "string") return 0;
  return child.length;
});

export const numbers = each(nodes, child => {
  if (typeof child === "number") return child.toFixed(2);
  return "";
});

// The negated branch keeps everything else.
export const rest = each(nodes, child => {
  if (typeof child === "string") return "s";
  const notString: Leaf | number | null | undefined = child;
  return notString === null ? "n" : "o";
});

// Written directly (no inference) this always worked; keep it honest.
export function direct(child: Nested): number {
  if (typeof child !== "string") return 0;
  return child.length;
}

// NEGATIVES — the guard must still exclude what it excludes.
export const bad1 = each(nodes, child => {
  if (typeof child !== "string") return 0;
  return child.zzqq1;
});

export const bad2 = each(nodes, child => {
  if (typeof child !== "number") return 0;
  return child.zzqq2;
});
