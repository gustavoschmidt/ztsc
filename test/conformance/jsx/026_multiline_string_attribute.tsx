// A JSX attribute's quoted value runs to the matching quote and nothing
// else: a raw line break is content, and `\` is a literal byte rather than
// an escape. ztsc lexed it with the ordinary string rule, which ends a
// string at the newline, so the attribute reported "expected an expression"
// and the rest of the element cascaded.
declare namespace JSX {
  interface Element {}
  interface IntrinsicElements {
    div: { title?: string; n?: number };
  }
}

const multiline = (
  <div
    title="line one
           line two"
    n={1}
  />
);

// Single quotes take the same rule.
const singleQuoted = <div title='line one
line two' />;

// `\` is literal, and `<`, `>`, `/`, `{` inside the value are content.
const literalBackslash = <div title="a\b" />;
const punctuation = <div title="a > b / c { d" />;

// The value is still a string literal, so the attribute is type-checked.
const wrongType = <div n="oops" />;
