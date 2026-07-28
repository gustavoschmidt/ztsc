// When a homomorphic mapped type distributes over a union source, the VALUE
// template must be re-bound per constituent: tsc instantiates the whole map
// with `T := A`, so `T[P]` becomes `A[P]`. Passing the union through unchanged
// resolved every property against the WHOLE union — `(A|B)["ax"]` is `unknown`
// and the discriminant widened to `"a" | "b"` on both constituents, so no
// discriminant / `in` narrowing could ever select a member.
// Distilled from excalidraw's `Mutable<ExcalidrawElement>`.
type Mutable<T> = { -readonly [P in keyof T]: T[P] };

type Text = { readonly type: "text"; readonly autoResize: boolean };
type Arrow = {
  readonly type: "arrow";
  readonly endBinding: { id: string } | null;
};
type El = Text | Arrow;

// the property types survive as themselves, not `unknown`.
const m: Mutable<Text> = { type: "text", autoResize: true };
const ok1: boolean = m.autoResize;

// a discriminant check selects one constituent of the distributed map.
export const f = (e: Mutable<El>) => {
  if (e.type === "arrow") {
    e.endBinding = null; // ok — `-readonly` applied, arm selected
    return e.endBinding;
  }
  return e.autoResize; // ok — the other arm
};

// `in` narrowing selects a constituent too.
export const g = (e: Mutable<El>) => {
  if ("endBinding" in e && e.endBinding) return e.endBinding.id;
  return "";
};

// negative control: a member of the WRONG arm is still rejected after the
// discriminant narrows.
export const h = (e: Mutable<El>) => {
  if (e.type === "arrow") return e.autoResize; // TS2339
  return false;
};

// negative control: the map is still a union, so an unguarded arm-specific
// property does not exist on it.
export const i = (e: Mutable<El>) => e.autoResize; // TS2339

// negative control: `Partial` over a union distributes the same way, and the
// discriminant of the selected arm keeps its own literal type.
type P<T> = Partial<T>;
export const j = (e: P<El>) => {
  const t: "text" | undefined = e.type; // TS2322: "arrow" is in the union too
  return t;
};

export { ok1 };
