// A truthy optional-*call* chain (`a?.m()`) implies its receiver did not
// short-circuit, so the receiver narrows to non-null — symmetric with the
// optional-*member* truthiness rule.
declare const a: { m(): string } | null;
let r1: { m(): string };
if (a?.m()) {
  r1 = a; // clean: a narrowed to non-null
}

// The `!x?.m()` early-return guard narrows on its fall-through.
function pick(b: { m(): string } | null, fallback: { m(): string }): { m(): string } {
  if (!b?.m()) {
    return fallback;
  }
  return b; // clean: b narrowed to non-null
}

// NEG CONTROL: the falsy branch of an optional-call chain says nothing about
// the receiver (it may be null → short-circuit, or non-null with a falsy
// result), so it must NOT narrow.
function bad(cc: { m(): string } | null): { m(): string } {
  if (cc?.m()) {
    return cc; // clean here (truthy branch narrows)
  }
  return cc; // TS2322: cc still possibly null
}
