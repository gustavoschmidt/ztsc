declare namespace JSX {
  interface Element {}
  interface IntrinsicElements {}
}

// A component declared as a function merged with a namespace types as an
// intersection (function value & namespace object). Its props must still be
// checked — every attribute was previously silently unchecked.
declare function Icon(props: { name: 'add' | 'home' }): JSX.Element;
declare namespace Icon {
  var displayName: string;
}

// Good attribute — no error.
const ok = <Icon name="add" />;

// Bad attribute value — rejected (TS2322).
const bad = <Icon name="nope" />;

// A callable object (call-signature-bearing interface) used as a component
// also has its props checked.
interface Callable {
  (props: { label: string }): JSX.Element;
  displayName: string;
}
declare const Widget: Callable;
const w = <Widget label={5} />;
