// A destructured binding inherits the narrowing of the property it comes from,
// evaluated at the declaration's position in the flow graph.
type El = { type: string; id: string };
type St = { multiElement: El | null; other: number | null };

declare const state: St;

// narrowed at the declaration
export function a() {
  if (state.multiElement) {
    const { multiElement } = state;
    const ok: El = multiElement;
    return ok;
  }
  return null;
}

// renamed binding
export function b() {
  if (state.multiElement) {
    const { multiElement: m } = state;
    const ok: El = m;
    return ok;
  }
  return null;
}

// NEGATIVE: declared BEFORE the guard — not narrowed
export function c() {
  const { multiElement } = state;
  if (state.multiElement) {
    const bad: El = multiElement; // TS2322
    return bad;
  }
  return null;
}

// NEGATIVE: the guard is on a different property
export function d() {
  if (state.other) {
    const { multiElement } = state;
    const bad: El = multiElement; // TS2322
    return bad;
  }
  return null;
}

// a local initialized from a call still works — the LOCAL is the reference
declare function getSt(): St;
export function e() {
  const st = getSt();
  if (st.multiElement) {
    const { multiElement } = st;
    const ok: El = multiElement;
    return ok;
  }
  return null;
}

// nested pattern: the path extends one link at a time
type Outer = { inner: { leaf: El | null } };
declare const outer: Outer;
export function f() {
  if (outer.inner.leaf) {
    const {
      inner: { leaf },
    } = outer;
    const ok: El = leaf;
    return ok;
  }
  return null;
}

// NEGATIVE for the nested form: guard on a sibling
type Outer2 = { inner: { leaf: El | null; other: number | null } };
declare const outer2: Outer2;
export function g() {
  if (outer2.inner.other) {
    const {
      inner: { leaf },
    } = outer2;
    const bad: El = leaf; // TS2322
    return bad;
  }
  return null;
}

// `this`-rooted
class K {
  state: St = { multiElement: null, other: null };
  m() {
    if (this.state.multiElement) {
      const { multiElement } = this.state;
      const ok: El = multiElement;
      return ok;
    }
    return null;
  }
}
export { K };

// a default value still strips `undefined` after the narrowing
type Opt = { p?: El };
declare const opt: Opt;
export function h() {
  const { p = { type: "x", id: "y" } } = opt;
  const ok: El = p;
  return ok;
}
