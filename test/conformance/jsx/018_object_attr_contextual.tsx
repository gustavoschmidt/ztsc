declare namespace JSX {
  interface Element {}
  interface IntrinsicElements {}
}

// An object-literal JSX attribute value is contextually typed by the target
// prop type (like `style={{…}}` against `CSSProperties`). A literal-valued
// property is typed by the corresponding target member: against a union of
// string literals it keeps its literal type instead of widening to `string`.
type Style = { position?: 'absolute' | 'relative'; z?: number };
declare function Box(props: { style?: Style }): JSX.Element;

// `position: 'absolute'` stays the literal against `'absolute' | 'relative'` —
// no error (before the contextual-typing fix this widened to `string`).
const ok = <Box style={{ position: 'absolute', z: 1 }} />;

// A non-matching literal is still rejected (negative control).
const bad = <Box style={{ position: 'fixed' }} />;
