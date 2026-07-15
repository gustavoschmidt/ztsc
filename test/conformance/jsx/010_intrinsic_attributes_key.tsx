declare namespace JSX {
  interface Element {}
  interface IntrinsicAttributes { key?: string | number; }
  interface IntrinsicElements {
    div: { id?: string };
  }
}
declare function Item(props: { label: string }): JSX.Element;

// `key` comes from JSX.IntrinsicAttributes: allowed on components...
const ok = <Item label="a" key="k" />;
// ...but never required.
const alsoOk = <Item label="b" />;
// Excess on a component is still caught (target includes IntrinsicAttributes).
const excess = <Item label="c" zzz={1} />;
// Intrinsic elements do NOT get IntrinsicAttributes: `key` on `div` is excess
// unless declared in the element's own props.
const bad = <div key="k" />;
