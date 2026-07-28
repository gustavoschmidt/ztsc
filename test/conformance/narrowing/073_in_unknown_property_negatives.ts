// Negatives for the unknown-name `in` rule: the synthesized member is
// `Record<n, unknown>`, so the property is `unknown` — usable, not `any` — and
// the intersection keeps the original constituents intact.
type Ev = { clientX: number; clientY: number };
type A = { kind: "a"; x: number };
type B = { kind: "b"; y: number };

export const a = (e: Ev) => {
  if ("pointerType" in e) {
    const s: string = e.pointerType; // error: unknown is not string
    return s;
  }
  return "";
};

// the original members survive the intersection
export const b = (e: Ev) => {
  if ("pointerType" in e) {
    const bad: string = e.clientX; // error: number is not string
    return bad;
  }
  return "";
};

// a known name still filters, so the negative branch has no `x`
export const c = (v: A | B) => {
  if ("x" in v) {
    return v.x;
  }
  return v.x; // error: 'x' does not exist on B
};

// the false branch of an unknown name did not add anything
export const d = (e: Ev) => {
  if ("pointerType" in e) {
    return 1;
  }
  return e.pointerType; // error: no such property on Ev
};
