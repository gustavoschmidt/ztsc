// The `?.[expr]` (element-access) link of an optional chain narrows its
// receiver the same way `?.p` does — a truthy chain says the receivers did not
// short-circuit. The property form was handled; the element form is a
// different node tag and fell through to the no-op default.
declare const m: string[] | null;
declare const i: number;

export function chain() {
  if (m?.[2]) {
    // `m` is non-null here.
    return m[3].length;
  }
  // …and only here.
  return m[0].length;
}

// The guard-and-return shape, which is how the receiver narrowing is usually
// written.
export function guard() {
  if (!m?.[i]) {
    return 0;
  }
  return m.length;
}

// A deeper chain: the containment rule reaches every receiver on the spine.
declare const nested: { xs: string[] | null } | null;

export function deep() {
  if (nested?.xs?.[0]) {
    return nested.xs.length;
  }
  return 0;
}

// The falsy branch of an optional element chain says nothing about the
// receiver (it may have short-circuited).
export function falsyBranch() {
  if (!m?.[2]) {
    return m[0].length;
  }
  return 0;
}

// Property form, unchanged control.
declare const o: { p?: { q: number } } | null;

export function propForm() {
  if (o?.p) {
    return o.p.q;
  }
  return 0;
}
