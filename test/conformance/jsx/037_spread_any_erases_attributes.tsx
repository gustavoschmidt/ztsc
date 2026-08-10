// tsc's `createJsxAttributesTypeFromAttributesProperty` ends with
//
//     return hasSpreadAnyType ? anyType : spread;
//
// so ONE spread attribute whose type is `any` makes the whole attributes
// object `any`, and every check the props type would drive is answered by
// that `any`: no per-attribute assignability, no excess property, no missing
// required prop, no weak type. An un-enumerable spread that is NOT `any` (a
// union, a type parameter, an index signature) still builds a real spread
// type and keeps checking.
declare namespace JSX {
  interface Element {}
  interface IntrinsicElements {}
  interface IntrinsicAttributes {}
}
declare function Widget(props: {a: number; b: string}): JSX.Element;

declare const anything: any;
// `web: (value: any) => any` — the react-native identity-on-web helper — is
// how this shape reaches real code.
declare function web(value: any): any;

// Excess, wrong-typed and missing props are all erased by the `any` spread.
const excess = <Widget {...anything} nope="x" />;
const wrongValue = <Widget {...anything} a="not a number" />;
const missing = <Widget {...anything} />;
const helper = <Widget {...web({nope: 1})} a={1} b="x" nope={2} />;

// The spread's own expression is still checked: `bad` is not declared.
// (TS2304 on the next line.)
const stillChecked = <Widget {...bad} a={1} b="x" />;

// Without the `any` spread every one of those is an error again.
const excess2 = <Widget a={1} b="x" nope="y" />;
const wrongValue2 = <Widget a="not a number" b="x" />;
const missing2 = <Widget />;
