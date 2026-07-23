declare namespace JSX {
  interface Element {}
  interface IntrinsicElements {}
}

// An array-literal JSX attribute value is contextually typed by the target
// prop type (like `radius={[8, 8, 8, 8]}` on a recharts `<Bar>`). Against a
// union that includes a fixed-length tuple the literal forms the tuple instead
// of widening to `number[]`; against an array of a string-literal union each
// element keeps its literal.
type Radius = number | [number, number, number, number];
declare function Bar(props: { radius?: Radius; kinds?: ('a' | 'b')[] }): JSX.Element;

// Tuple member of the union is picked — no error (before the fix this widened
// to `number[]` and failed the tuple).
const ok = <Bar radius={[8, 8, 8, 8]} />;
// Element literals kept against the literal-union array.
const ok2 = <Bar kinds={['a', 'b', 'a']} />;

// Wrong tuple length is still rejected (negative control): a 3-element literal
// matches neither `number` nor the 4-tuple.
const bad = <Bar radius={[1, 2, 3]} />;
