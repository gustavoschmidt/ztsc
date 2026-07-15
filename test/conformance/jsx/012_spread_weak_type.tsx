declare namespace JSX {
  interface Element {}
  interface IntrinsicAttributes { key?: string | number; }
  interface IntrinsicElements {
    span: { id?: string };
  }
}
declare function Loose(props: { a?: number }): JSX.Element;
declare const noCommon: { q: number };
declare const someCommon: { a: number; q: number };

// Weak target (all props optional): a spread sharing no props is TS2559.
const bad = <Loose {...noCommon} />;
// Sharing at least one prop is fine.
const ok = <Loose {...someCommon} />;
// Also applies to intrinsic elements.
const badSpan = <span {...noCommon} />;
// A literal attribute in common suppresses it.
const okLit = <Loose {...noCommon} a={1} />;
