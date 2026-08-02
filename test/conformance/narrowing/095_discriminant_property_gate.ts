// Narrowing a reference by one of its PROPERTIES — `x.k === lit`,
// `switch (x.k)`, `if (x.p)` — is gated in tsc by
// `getDiscriminantPropertyAccess`, which picks
// `declaredType.flags & Union ? declaredType : computedType` and then asks
// `isDiscriminantProperty`. That answers `false` for a non-union, and for a
// union whose per-constituent property types are uniform or carry no unit
// type. Every read below is of a property of the PARENT reference, so it
// would be a TS2339 on `never` if the parent had been narrowed; none of
// these shapes narrows it. The shapes that ARE discriminants still collapse
// the parent — see the `_negatives` file.

// A NON-UNION object is never discriminated: the `else` branch keeps the
// declared type.
declare let one: { type: "C"; a: number };
export function nonUnionEquality() {
  if (one.type === "C") {
    return 0;
  }
  return one.a;
}

// The classic exhaustiveness idiom, on a non-union: the `default:` arm still
// has the whole object to report from.
type Encoded = { encoded: string; encoding: "bstring"; compressed: boolean };
export function nonUnionSwitch(data: Encoded) {
  switch (data.encoding) {
    case "bstring":
      return data.encoded;
    default:
      return data.compressed;
  }
}

// A union property whose constituent types are all the same (`id: string`
// everywhere) is not a discriminant, so an equality test on it says nothing
// about which constituent is live.
type Line = { kind: "line"; id: string; locked: boolean; pts: number };
type Arrow = { kind: "arrow"; id: string; locked: boolean; head: number };
declare const shape: Line | Arrow;
declare const wanted: string | undefined;
export function uniformProperty() {
  if (shape.id === wanted && !shape.locked) {
    return shape.kind;
  }
  return "";
}

// Neither is a property whose types differ but include no unit type: the
// falsy branch of `el.lineHeight` must leave the union alone, so the `||`'s
// right operand can still read the same reference.
type Branded = number & { _brand: "lh" };
type TextEl = { kind: "text"; lineHeight: Branded; height: number; font: number };
type RectEl = { kind: "rect"; lineHeight: number; height: number; font: number };
declare function detect(e: { height: number }): number;
declare function fallback(f: number): number;
export function nonUnitProperty(el: TextEl | RectEl) {
  return el.lineHeight || (el.height ? detect(el) : fallback(el.font));
}

// `boolean` IS a literal type for this rule, but a property that is
// `boolean` on every constituent is still uniform — not a discriminant, so
// both branches keep the whole union.
export function uniformBoolean(s: Line | Arrow) {
  if (s.locked) {
    return s.kind;
  }
  return s.kind;
}
