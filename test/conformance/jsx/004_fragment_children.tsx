declare namespace JSX {
  interface Element {}
  interface IntrinsicElements {
    div: {};
  }
}
declare const value: number;
const frag = <><div>{value}</div>{value}</>;
const bad = <div>{missingVar}</div>;
