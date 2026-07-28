// A loop label that is still being computed answers a re-entrant query with
// the union of the antecedent types gathered so far, not with the declared
// type (tsc `getTypeAtFlowLoopLabel`). Every case below reads the guarded
// reference from inside the loop *and* assigns it there, so the read is what
// re-enters the label.
declare const rec: Record<string, string>;
declare function find(d: unknown): string | undefined;

// parameter, for..in, right-hand side reads the reference itself
export const a = (x?: string) => {
  if (x === undefined) throw new Error("x");
  for (const k in rec) {
    x = x.replace("a", k);
  }
  return x;
};

// same with `return` as the guard's exit
export const b = (x?: string) => {
  if (x === undefined) return "";
  for (const k in rec) {
    x = x.replace("a", k);
  }
  return x;
};

// while loop
export const c = (x?: string) => {
  if (x === undefined) throw new Error("x");
  while (rec.a) {
    x = x.replace("a", "b");
  }
  return x;
};

// annotated local, no statement after the loop (the label is only ever
// demanded from inside the loop body)
export const d = () => {
  let x: string | undefined = find(1);
  if (x === undefined) throw new Error("x");
  for (const k in rec) {
    x = x.replace("a", k);
  }
};

// nested loops
export const e = (x?: string) => {
  if (x === undefined) throw new Error("x");
  for (const k in rec) {
    for (const j in rec) {
      x = x.replace(k, j);
    }
  }
  return x;
};

// a guarded `for..of` binding stays narrowed inside a nested loop
type Text = { kind: "text"; text: string };
type Line = { kind: "line" };
declare const items: readonly (Text | Line)[];
export const f = () => {
  const out: string[] = [];
  for (const el of items) {
    if (el.kind !== "text") continue;
    for (const ch of el.text) {
      out.push(ch);
    }
    let i = 0;
    while (i < 3) {
      out.push(el.text);
      i++;
    }
  }
  return out;
};
