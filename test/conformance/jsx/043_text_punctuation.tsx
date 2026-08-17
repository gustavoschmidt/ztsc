// A bare `}` or `>` in JSX CHILD TEXT is TS1381 / TS1382 — the two characters
// that would otherwise have ended a container or a tag, and that JSX asks the
// author to spell `{'}'}` / `&rbrace;` and `{'>'}` / `&gt;`. tsc's scanner
// reports one per byte as it walks the text, so a line with two of them
// answers twice.
//
// The `>` case also pins the tag-close scan: `<div>>` munches as `<`, `div`,
// `>>`, and the second `>` belongs to the CHILD TEXT, not to the tag.
declare namespace JSX {
  interface Element {}
  interface IntrinsicElements {
    div: {};
  }
}

const a = <div>}</div>;
const b = <div>></div>;
const c = <div>{"foo"}}</div>;
const d = <div>{"foo"}></div>;
const e = <div>}{"foo"}</div>;
const f = <div>>{"foo"}</div>;
const g = <div>x &gt; y {"is"} z {">"}</div>;
const h = <div>a > b } c</div>;
const i = <div>{">"}</div>;
