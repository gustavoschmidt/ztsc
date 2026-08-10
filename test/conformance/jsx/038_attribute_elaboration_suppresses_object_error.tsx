// tsc's `checkTypeRelatedToAndOptionallyElaborate`:
//
//     if (!errorNode || !elaborateError(expr, source, target, …)) {
//         return checkTypeRelatedTo(source, target, relation, errorNode, …);
//     }
//     return false;
//
// so once `elaborateJsxComponents` -> `elaborateElementwise` has reported on a
// single ATTRIBUTE, the top-level relation never runs — and with it go the
// whole-attributes-object diagnostics: excess property, missing required prop,
// weak type. `elaborateElementwise` `continue`s over an attribute the target
// does not know, so an EXCESS attribute alone never triggers the suppression;
// only a KNOWN prop whose value mismatches does.
//
// This is not cosmetic: tsc's error lands on the narrow attribute, which a
// `@ts-expect-error` written above that attribute absorbs, while the
// whole-object error lands on the tag or on a different attribute. Every
// element below puts each attribute on its own line so the snapshot pins
// WHICH node is blamed.
declare namespace JSX {
  interface Element {}
  interface IntrinsicElements {}
  interface IntrinsicAttributes {}
}

interface Props {
  a: number;
  b: string;
}
declare function Widget(props: Props): JSX.Element;

// A wrong-typed KNOWN attribute reports on that attribute; the excess `nope`
// and the missing `b` are both suppressed with the outer relation.
const one = (
  <Widget
    a="wrong"
    nope={1}
  />
);

// Without a mismatching attribute both whole-object reports come back — the
// excess one on the excess attribute, the missing one on the tag.
const excess = (
  <Widget
    a={1}
    b="x"
    nope={1}
  />
);
const missing = (
  <Widget
    a={1}
  />
);

// The elaboration reaches through a JSX expression container into an
// object-literal attribute value, so the report is on the offending MEMBER,
// not on the attribute name and not on the whole element — and it likewise
// suppresses the missing-`other` report.
interface Bag {
  inner: {n: number};
  other: string;
}
declare function Holder(props: Bag): JSX.Element;
const nested = (
  <Holder
    inner={{
      n: 'no',
    }}
  />
);
