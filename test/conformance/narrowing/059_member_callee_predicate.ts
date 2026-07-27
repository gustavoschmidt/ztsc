// A user-defined type guard reached through a MEMBER callee (`m.isA(e)`,
// `this.g.isA(e)`) must narrow exactly like a bare-identifier callee.
//
// The guard machinery consults the callee's *memoized* node type, because
// re-checking a member callee from inside the flow walk can re-enter an
// in-progress loop query and re-widen the receiver. But a function without a
// return annotation has its `return` expressions checked by the inferred-return
// probe, i.e. before the `if` condition that guards them — so the callee was
// not memoized yet and the guard was silently dropped. The callee's declared
// type is now resolved structurally in that case.

type A = { k: "a"; av: number };
type B = { k: "b"; bv: string };
type U = A | B;

declare const e: U;

// POSITIVE (must NOT error) --------------------------------------------------

// Method-shaped guard on an object, in a function with an INFERRED return type.
declare const obj: { isA(x: U): x is A; isB(x: U): x is B };
function p_inferred_return_method() {
  if (obj.isA(e)) {
    return e.av;
  }
  return 0;
}

// Property-shaped (arrow) guard, inferred return type.
declare const arrow: { isB: (x: U) => x is B };
function p_inferred_return_arrow() {
  if (arrow.isB(e)) {
    return e.bv;
  }
  return "";
}

// Class instance method, inferred return type.
class M {
  isA(x: U): x is A {
    return x.k === "a";
  }
}
declare const m: M;
function p_class_method() {
  if (m.isA(e)) {
    return e.av;
  }
  return 0;
}

// A deeper receiver path, inferred return type.
declare const deep: { inner: { isA(x: U): x is A } };
function p_deep_path() {
  if (deep.inner.isA(e)) {
    return e.av;
  }
  return 0;
}

// Regression: the same guard with an EXPLICIT return annotation, and outside a
// return position — both already worked and must keep working.
function p_annotated(): number {
  if (obj.isA(e)) {
    return e.av;
  }
  return 0;
}
function p_statement_position(): void {
  if (obj.isA(e)) {
    const n: number = e.av;
    void n;
  }
}

// Regression: a bare-identifier callee still narrows.
declare function isA2(x: U): x is A;
function p_identifier_callee() {
  if (isA2(e)) {
    return e.av;
  }
  return 0;
}

// The negative branch narrows too.
function p_else_branch() {
  if (obj.isA(e)) {
    return 0;
  }
  return e.bv;
}

// NEGATIVE (must error) ------------------------------------------------------

// Without the guard the union has no such property.
function n_unguarded() {
  return e.av; // TS2339
}

// The guard's own complement does not grant the other arm's property.
function n_wrong_arm() {
  if (obj.isA(e)) {
    return e.bv; // TS2339
  }
  return "";
}
