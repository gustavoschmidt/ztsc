// tsc's `getContextualTypeForChildJsxExpression`:
//
//     return childFieldType && (realChildren.length === 1 ? childFieldType :
//         mapType(childFieldType, t =>
//             isArrayLikeType(t)
//                 ? getIndexedAccessType(t, getNumberLiteralType(childIndex))
//                 : t, /*noReductions*/ true));
//
// so with SEVERAL semantic children each one is typed by the `children` field
// mapped through its array-like constituents at that child's index, and the
// non-array constituents type the child whole. ztsc had only the
// single-child half, so the multi-child render-prop idiom — social-app's
// `<PagerWithHeader>{a}{b}{c}</PagerWithHeader>`, whose `children` is
// `(((p: P) => JSX.Element) | null)[] | ((p: P) => JSX.Element)` — left every
// render prop's destructured parameter implicit `any`.
declare namespace JSX {
  interface Element {}
  interface IntrinsicElements {}
  interface IntrinsicAttributes {}
  interface ElementChildrenAttribute {
    children: {};
  }
}

interface ChildParams {
  headerHeight: number;
  scrollElRef: {current: number | null};
}

declare function Pager(props: {
  children:
    | (((p: ChildParams) => JSX.Element) | null)[]
    | ((p: ChildParams) => JSX.Element);
}): JSX.Element;

declare const flag: boolean;
declare function Row(props: {n: number}): JSX.Element;

// Three children: every destructured parameter is typed, so none is an
// implicit `any` (TS7031) and a wrong use of one is a real error.
const many = (
  <Pager>
    {flag ? ({headerHeight}) => <Row n={headerHeight} /> : null}
    {flag ? ({scrollElRef}) => <Row n={scrollElRef} /> : null}
    {({headerHeight, scrollElRef}) => (
      <Row n={headerHeight + (scrollElRef.current ?? 0)} />
    )}
  </Pager>
);

// One child: the field type types it directly, non-array arm included.
const one = <Pager>{({headerHeight}) => <Row n={headerHeight} />}</Pager>;
