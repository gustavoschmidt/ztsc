// TS4.9: `n in x` for a name no constituent declares narrows the true branch to
// `x & Record<n, unknown>` instead of filtering (tsc `narrowByInKeyword`).
type Ev = { clientX: number; clientY: number };
type A = { kind: "a"; x: number };
type B = { kind: "b"; y: number };

// non-union subject, unknown name
export const a = (e: Ev) => {
  if ("pointerType" in e && e.pointerType === "touch") {
    return 1;
  }
  return 0;
};

// union subject, name on no constituent
export const b = (v: A | B) => {
  if ("extra" in v) {
    return v.extra;
  }
  return undefined;
};

// known name still filters the union
export const c = (v: A | B) => {
  if ("x" in v) {
    const n: number = v.x;
    return n;
  }
  const m: number = v.y;
  return m;
};

// the false branch of an unknown name leaves the subject alone
export const d = (e: Ev) => {
  if ("pointerType" in e) {
    return 1;
  }
  return e.clientX;
};

// an index signature counts as declaring the name, so this still filters
export const e = (v: Record<string, number> | A) => {
  if ("anything" in v) {
    return v;
  }
  return null;
};
