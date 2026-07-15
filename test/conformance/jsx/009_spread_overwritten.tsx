declare namespace JSX {
  interface Element {}
  interface IntrinsicElements {}
}
declare function Widget(props: { a: number; b: string }): JSX.Element;
const full = { a: 1, b: "x" };

// Literal attributes re-provided by a LATER spread are overwritten -> TS2783
// (one per shadowed attribute, at the attribute name).
const shadowed = <Widget a={5} b={"y"} {...full} />;
// The other order is fine: literal after spread wins silently.
const fine = <Widget {...full} a={7} />;
// An excess literal attribute alongside a spread is still excess -> TS2322.
const excess = <Widget {...full} zzz={1} />;
