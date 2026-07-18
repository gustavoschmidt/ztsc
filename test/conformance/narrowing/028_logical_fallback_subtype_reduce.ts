// `x || []` / `x ?? []` must subtype-reduce the empty-array fallback branch
// (tsc's UnionReduction.Subtype) so the result is a single array type and a
// following `.map(...)` stays callable — otherwise the two-array union
// mis-reports TS2349 "not callable".
function pick(items: number[] | undefined): string[] {
  const list = items || [];
  return list.map((n) => n.toString());
}

function pick2(items: string[] | null): number[] {
  const list = items ?? [];
  return list.map((s) => s.length);
}

// property-access optional-chain root, the real dogfood-project idiom.
interface Item { id: string; name: string; }
interface Data { overlay?: Item[]; }
function names(data: Data): string[] {
  const xs = data.overlay?.filter((i) => i.id !== "x") || [];
  return xs.map((i) => i.name);
}

void pick; void pick2; void names;
