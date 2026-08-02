// The other side of the `isDiscriminantProperty` gate: a property whose
// per-constituent types are NON-UNIFORM and include a unit type really is a
// discriminant, so it still narrows the PARENT — all the way to `never` —
// and reading any member off that `never` is a TS2339.

type A = { type: "C"; a: number };
type B = { type: "D"; d: number };

// Declared type is a union, so the guard applies even after the reference
// has already been narrowed to a single constituent.
export function reNarrow(y: A | B) {
  if (y.type === "C") {
    if (y.type === "C") {
      return y.a;
    }
    return y.a;
  }
  return y.d;
}

// `switch` on the same discriminant: the `default:` clause is empty.
export function switchDefault(y: A | B) {
  switch (y.type) {
    case "C":
      return y.a;
    case "D":
      return y.d;
    default:
      return y.a;
  }
}

// Truthiness of a discriminant property (`ok: true` vs `ok: false`) narrows
// the parent, so the wrong branch has no constituent left.
type Ok = { ok: true; value: number };
type Err = { ok: false; error: number };
export function truthyDiscriminant(r: Ok | Err) {
  if (r.ok) {
    if (!r.ok) {
      return r.error;
    }
    return r.value;
  }
  return r.error;
}

// A `p?: undefined` / `p: string` pair is the same rule: `undefined` is a
// unit type, so `p` discriminates and `if (v.p)` drops `WithoutP`. Re-testing
// it does NOT empty the branch — `string`'s falsy part is `""`, not `never`,
// so `WithP` survives and this last read is legal.
type WithP = { tag: 1; p: string };
type WithoutP = { tag: 2; p?: undefined };
export function optionalUndefinedDiscriminant(v: WithP | WithoutP) {
  if (v.p) {
    if (!v.p) {
      return v.tag;
    }
    return v.tag;
  }
  return v.tag;
}
