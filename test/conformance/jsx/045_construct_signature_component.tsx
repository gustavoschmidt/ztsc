declare namespace JSX {
  interface Element {}
  interface ElementClass { render(): void; }
  interface ElementAttributesProperty { props: {}; }
  interface IntrinsicElements { div: { id?: string }; }
}

// A component whose type is a bare CONSTRUCT signature rather than a class
// declaration. tsc's `getUninstantiatedJsxSignaturesOfType` falls back to the
// construct signatures when there is no call signature, and
// `getJsxPropsTypeFromClassType` reads the attributes target off the member of
// the RETURN type named by `JSX.ElementAttributesProperty`.
declare const Ctor: new () => { props: { a: number }; render(): void };
const c1 = <Ctor a={1} />;
const c2 = <Ctor a="s" />;
const c3 = <Ctor b={1} />;
const c4 = <Ctor />;

// A GENERIC construct signature infers its type arguments from the attributes,
// through the props member of the still-generic instance.
declare const G: new <T>(p: T) => { props: { v: T }; render(): void };
const g1 = <G v={1} />;
const g2 = <G<string> v={1} />;

// No `props` member on the instance: TS2607, but only where an attribute (or a
// spread, which is one too) is actually written.
declare const NoProps: new () => { render(): void };
const n1 = <NoProps x={1} />;
const n2 = <NoProps {...{ x: 1 }} />;
const n3 = <NoProps />;

// Neither callable nor constructable: still TS2604.
declare const Plain: { a: number };
const p1 = <Plain />;
