declare namespace JSX {
  interface Element {}
  interface IntrinsicElements {}
}
declare function Widget(props: { a: number; b: string }): JSX.Element;

const full = { a: 1, b: "x" };
const partial = { a: 1 };

// Spread satisfies all required props.
const ok = <Widget {...full} />;
// Spread missing a required prop -> TS2322 at the tag.
const missing = <Widget {...partial} />;
// A literal after the spread fills the gap (later wins).
const filled = <Widget {...partial} b="y" />;
// ...but its value is still type-checked.
const wrongLate = <Widget {...partial} b={42} />;
// A non-object spread is TS2698 (and the props stay unsatisfied -> TS2322).
const notObj = <Widget {...123} />;
