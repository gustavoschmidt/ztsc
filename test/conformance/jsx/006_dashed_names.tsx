declare namespace JSX {
  interface Element {}
  interface IntrinsicElements {
    div: { id?: string; [name: string]: any };
    span: { id?: string };
  }
}
declare const value: number;

// `data-*` / `aria-*` names lex as one token and are exempt from excess
// and assignability checks (tsc), on elements with or without an index
// signature.
const a = <div data-foo="x" aria-label="hi" id="y" />;
const b = <span data-x="1" aria-hidden={true} />;
const c = <div data-num={value} />;

// The value expression of a hyphenated attribute is still checked.
const d = <span data-bad={missingVar} />;

// A non-hyphenated excess property still errors.
const e = <span extra="z" />;

// A hyphenated (custom-element) tag is looked up in IntrinsicElements.
const f = <my-widget />;
