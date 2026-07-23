// A member-path truthiness guard must survive a method CALL on the narrowed
// receiver inside a loop body. The loop's call statement forms an assertion-
// candidate flow node; walking the loop back-edge re-enters the callee check
// while the loop label is still in progress (receiver transiently re-widened),
// which used to raise a spurious "possibly undefined" on `rule.abstract` at the
// `.startsWith(...)` call. The flow-narrowing callee re-check must not emit
// diagnostics — the authoritative top-down check runs at the narrowed type.
// Minimized repro of the dogfood project's get-legend transform.

interface Rule {
  abstract?: string;
}

// POSITIVE (must NOT error) --------------------------------------------------
// Method call on a member-path receiver guarded truthy, inside a loop.
function p_call_in_loop(rule: Rule, arr: unknown[]): void {
  for (const _ of arr) {
    if (rule.abstract) {
      rule.abstract.startsWith("http"); // OK: abstract narrowed to string
    }
  }
}

// Same, with the guard and the call fused on one line via `&&`.
function p_fused(rule: Rule, arr: unknown[]): void {
  for (const _ of arr) {
    if (rule.abstract && rule.abstract.startsWith("http")) {
      void 0;
    }
  }
}

// Regression: a real user-defined type guard call inside a loop still narrows.
function isStr(x: unknown): x is string {
  return typeof x === "string";
}
function p_guard_in_loop(v: unknown, arr: unknown[]): number {
  let total = 0;
  for (const _ of arr) {
    if (isStr(v)) {
      total += v.length; // OK: v narrowed to string
    }
  }
  return total;
}

// Regression: an assertion function call inside a loop still narrows after it.
function assertStr(x: unknown): asserts x is string {
  if (typeof x !== "string") throw new Error();
}
function p_assert_in_loop(v: unknown, arr: unknown[]): number {
  let total = 0;
  for (const _ of arr) {
    assertStr(v);
    total += v.length; // OK: v asserted string
  }
  return total;
}

// NEGATIVE CONTROL (MUST error) ----------------------------------------------
// No guard: the method call on the possibly-undefined member still errors.
function n_no_guard(rule: Rule, arr: unknown[]): void {
  for (const _ of arr) {
    rule.abstract.startsWith("http"); // error TS18048: abstract possibly undefined
  }
}
