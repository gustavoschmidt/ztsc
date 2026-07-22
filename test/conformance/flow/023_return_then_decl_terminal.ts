// A `return` followed by trailing code — a hoisted `function` declaration
// (the common hook pattern `return { … }; function helper() {…}`) or any
// dead statement — still makes the block terminal, so the inferred return
// type does NOT gain `undefined`. Reachability is a forward scan, not an
// "inspect the last statement only" rule.
function useThing() {
  const open = true;
  return { open, helper };

  function helper(): number {
    return 1;
  }
}
const t = useThing();
const a: boolean = t.open; // clean: t is not "possibly undefined"

// NEG CONTROL: a genuine fall-through past a partial `if` still yields
// `T | undefined`, so the result IS possibly undefined.
function maybe(x: boolean) {
  if (x) {
    return { v: 1 };
  }
}
const m = maybe(true);
const b = m.v; // TS18048: m possibly undefined
