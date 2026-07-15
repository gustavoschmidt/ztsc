declare namespace JSX {
  interface Element {}
  interface ElementChildrenAttribute { children: {}; }
  interface IntrinsicElements {}
}
declare function Panel(props: { title: string; children: string }): JSX.Element;

// JSX children satisfy the `children` prop named by ElementChildrenAttribute.
const ok = <Panel title="a">hello</Panel>;
// Without children the required prop is missing -> TS2322.
const missing = <Panel title="b" />;
// Same-line whitespace text is a meaningful (space) child...
const spaceChild = <Panel title="c">   </Panel>;
// ...but whitespace spanning a newline is trivia, not a child.
const trivia = <Panel title="d">
</Panel>;
