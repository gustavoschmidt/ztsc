declare namespace JSX {
  interface Element {}
  interface IntrinsicElements {
    div: { id?: string; "data-count"?: number };
  }
}

declare function use(x: unknown): void;

// A HYPHENATED attribute name (`data-*`, `aria-*`, or an application's own
// `connect-link`) is exempt from the excess-property and assignability checks
// — that is tsc's rule and ztsc had it — but it is NOT exempt from contextual
// typing. tsc looks the name up in the attributes type like any other, so on a
// props type carrying a string index signature the value gets the index VALUE
// as its contextual type. ztsc skipped the lookup outright, so a callback
// written as a hyphenated attribute had no contextual signature and its
// parameters went implicit-any.

type Bag = { plain: string } & {
  [key: string]: string | ((el: string) => string);
};
declare function Trans(props: Bag): JSX.Element;

// The undashed sibling already worked; the dashed one is the regression.
const ok = <Trans plain="p" link={(el) => el} />;
const dashed = <Trans plain="p" connect-link={(el) => el} />;

// The contextual type really flows: the parameter is the index value's
// parameter type, not `any`.
const flows = (
  <Trans
    plain="p"
    connect-link={(el) => {
      const s: string = el;
      use(s);
      return s;
    }}
  />
);

// Still exempt from the checks: a hyphenated name whose value does not match
// the index signature is not reported, and a hyphenated name absent from the
// props type is not an excess property.
const exempt = <Trans plain="p" some-thing={42} />;

// An intrinsic element's declared hyphenated prop keeps working.
const intrinsic = <div id="x" data-count={3} />;
