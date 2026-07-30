// Negatives: the deep spine narrows only the receivers the guard actually
// walked, and only on the asserting branch.
type Deep = { a?: { b?: { c?: { d?: { e?: { f?: string } } } } } };

// a sibling path is untouched
export function a(x: Deep, y: Deep): object {
  if (x.a?.b?.c?.d?.e?.f) {
    return y.a; // error: possibly 'undefined'
  }
  return {};
}

// the false branch says nothing
export function b(x: Deep): object {
  if (!x.a?.b?.c?.d?.e?.f) {
    return x.a; // error: possibly 'undefined'
  }
  return {};
}

// a link BEYOND the guarded spine keeps its own optionality
type Deeper = { a?: { b?: { c?: { d?: { e?: { f?: { g?: string } } } } } } };
export function c(x: Deeper): string {
  if (x.a?.b?.c?.d?.e?.f) {
    return x.a.b.c.d.e.f.g; // error: 'g' is optional
  }
  return '';
}
