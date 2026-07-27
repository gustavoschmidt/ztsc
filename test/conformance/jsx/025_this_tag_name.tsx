// A JSX tag name may be rooted at `this` (`<this.Component />`) — only the
// root of the chain, never a later member. ztsc's tag-name parse accepted
// only an identifier there and reported "expected an identifier".
//
// Props of a `this`-rooted tag are not compared here: ztsc does not yet
// check arguments through any `this.member` callee (a pre-existing checker
// gap, independent of this parse), so a props mismatch would be an accepted
// divergence rather than a statement about the tag name.
declare namespace JSX {
  interface Element {}
  interface ElementAttributesProperty {
    props: {};
  }
  interface IntrinsicElements {
    div: { id?: string };
  }
}

type Comp = (props: { n: number }) => JSX.Element;

class Host {
  Component: Comp = () => null as any;
  ns = { Inner: null as any as Comp };

  ok() {
    return <this.Component n={1} />;
  }
  okDeep() {
    return <this.ns.Inner n={2} />;
  }
  // The closing tag takes the same name form.
  okChildren() {
    return <this.Component n={3}>{null}</this.Component>;
  }
  // The tag is a real value expression, so it types as `JSX.Element`.
  okElement(): JSX.Element {
    return <this.Component n={4} />;
  }
  // A plain intrinsic tag, and a hyphenated custom element, are unaffected.
  intrinsic() {
    return <div id="x" />;
  }
}

// Away from a class the same shapes still work off an object value.
declare const o: { Component: Comp };
const viaObj = <o.Component n={5} />;
const viaObjBad = <o.Component n="x" />;
