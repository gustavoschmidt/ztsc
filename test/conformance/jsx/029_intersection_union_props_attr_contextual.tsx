declare namespace JSX {
  interface Element {}
  interface IntrinsicElements {}
}

// A component whose props are `Base & (VariantA | VariantB)` — the
// discriminated-props idiom, where the variants carry the props that only make
// sense together. An attribute living in ONE variant is not a property of the
// union, and the bare property lookup the attribute-value contextual type used
// has no union arm, so it found nothing: the value went uncontextually typed
// and a callback attribute's parameters fell to implicit `any` (TS7006).
// Object literals already read their contextual property the union-aware way.
type Props<T> = {
  options: { value: T; text: string }[];
  value: T | null;
  type?: "radio" | "button";
} & (
  | { type?: "radio"; group: string; onChange: (value: T) => void }
  | { type: "button"; onClick: (value: T, event: number) => void }
);

declare const Sel: <T extends Object>(props: Props<T>) => JSX.Element;
declare const SelC: (props: Props<string>) => JSX.Element;

// Generic component, variant A: `onChange`'s parameter is `T`, inferred here
// as `string` — the body's `value.length` proves it is not `any`.
export const a = (
  <Sel
    group="g"
    options={[{ value: "x", text: "X" }]}
    value={"x"}
    onChange={(value) => {
      const n: number = value.length;
      return n;
    }}
  />
);

// Variant B, two parameters.
export const b = (
  <Sel
    type="button"
    options={[{ value: "x", text: "X" }]}
    value={"x"}
    onClick={(value, event) => value.length + event}
  />
);

// Non-generic component, same shape.
export const c = (
  <SelC
    group="g"
    options={[{ value: "x", text: "X" }]}
    value={"x"}
    onChange={(value) => value.length}
  />
);

// NEGATIVE: the contextual type is a real type, not a licence. A parameter
// annotated incompatibly with it is still rejected.
export const d = (
  <SelC
    group="g"
    options={[{ value: "x", text: "X" }]}
    value={"x"}
    onChange={(value: number) => value}
  />
);
