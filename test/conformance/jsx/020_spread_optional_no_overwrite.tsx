declare namespace JSX {
  interface Element {}
  interface IntrinsicElements {}
}
declare function Widget(props: { a?: number; b?: string }): JSX.Element;

// A spread whose overlapping member is OPTIONAL does not overwrite a prior
// explicit attribute (tsc's checkSpreadPropOverrides fires only for a
// required spread member).
declare const optA: { a?: number };
const s1 = <Widget a={1} {...optA} />;

// A spread mixing an optional 'a' with a REQUIRED 'b': only 'b' is
// overwritten -> exactly one TS2783, at the 'b' attribute.
declare const mixed: { a?: number; b: string };
const s2 = <Widget a={1} b={"y"} {...mixed} />;

// Explicit attribute AFTER the spread wins silently, regardless of
// optionality in the spread.
const s3 = <Widget {...mixed} a={2} b={"z"} />;
