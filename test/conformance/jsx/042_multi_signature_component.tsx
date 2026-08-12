declare namespace JSX {
  interface Element {}
  interface IntrinsicAttributes {}
  interface IntrinsicElements {
    span: { className?: string };
  }
}

// A JSX element with a MULTI-SIGNATURE component type is resolved the way a
// call is: the whole signature list, first candidate that fits. This is the
// polymorphic-`as` shape every styled-components element is built out of — a
// non-generic signature that forbids `as`, followed by a generic one that
// infers the element from it. Taking `sigs[0]` unconditionally read
// `Type '"p"' is not assignable to type 'undefined'` on every one of them.
//
// NOT covered here: when NO candidate fits, tsc heads the failure with TS2769
// ("No overload matches this call") the way it does for a call; ztsc still
// reports the last candidate's own attribute error.
interface Poly<Own extends object> {
  (props: Own & { as?: never | undefined }): JSX.Element;
  <AsC extends string = "span">(props: Own & { as?: AsC | undefined }): JSX.Element;
}

declare const Text: Poly<{ $bold?: boolean; children?: unknown }>;

// The second signature, AsC = "p".
export const a = <Text as="p" $bold />;
// The first signature.
export const b = <Text $bold />;

// The same shape once a SIBLING CONSTITUENT of the props parameter answers
// only from a string INDEX SIGNATURE — here the still-free `Extra`, through
// its constraint. `getPropertyOfType` on an intersection consults no index
// signature at all, so `as` reads `AsC | undefined` and the attributes infer
// `AsC = "p"`. ztsc asked each constituent in isolation and took the index's
// `any`; since `any & (AsC | undefined)` is `any`, the attribute-driven
// inference had no target worth a candidate, `AsC` fell back to its default
// and the element read `Type '"p"' is not assignable to type '"span" |
// undefined'` — 136 keys' worth of it on outline.
//
// styled-components' real second signature reaches the same state by a longer
// road: its props are `StyledComponentProps<AsC, …> & { as?: AsC | undefined;
// … }`, whose first constituent is a conditional still deferred on the free
// `AsC`, and ztsc's apparent type for it bottoms out in a generic mapped type
// whose base constraint is `{ [x: string]: any }`.
interface Idx {
  [k: string]: any;
}

interface PolyIx<Own extends object> {
  (props: Own & { as?: never | undefined }): JSX.Element;
  <AsC extends string = "span", Extra extends Idx = {}>(
    props: Extra & Own & { as?: AsC | undefined },
  ): JSX.Element;
}

declare const Ix: PolyIx<{ $bold?: boolean; children?: unknown }>;

export const c1 = <Ix as="p" $bold />;
export const c2 = <Ix $bold />;

// Ordinary overloads on a function component, same rule.
interface Two {
  (props: { kind: "a"; n: number }): JSX.Element;
  (props: { kind: "b"; s: string }): JSX.Element;
}
declare const T2: Two;
export const d = <T2 kind="b" s="x" />;
export const e = <T2 kind="a" n={1} />;
