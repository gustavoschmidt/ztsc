declare namespace JSX {
  interface Element {}
  interface IntrinsicElements {}
}
declare function Widget(props: { a?: number; b?: string; c?: boolean }): JSX.Element;

type Props = { a: number; b: string } & { c: boolean };

// `{ a, ...rest }` gives rest = Omit<Props, "a">: 'a' is destructured out, so
// re-spreading rest does NOT overwrite the explicit `a` (no TS2783 for 'a').
// But 'b' remains REQUIRED in rest, so the explicit `b` before the spread is
// overwritten -> exactly one TS2783, at the 'b' attribute.
function F({ a, ...rest }: Props) {
  return <Widget a={a} b={"y"} {...rest} />;
}

// Destructuring every overlapping key out leaves nothing to overwrite.
function G({ a, b, c, ...rest }: Props) {
  return <Widget a={a} b={b} {...rest} />;
}
