declare namespace JSX {
  interface Element {}
  interface IntrinsicElements {
    div: { id?: string; tabIndex?: number };
    span: {};
  }
}
const ok = <div id="hello" tabIndex={3} />;
const nested = <div><span>text</span></div>;
const bad = <div id={5} />;
