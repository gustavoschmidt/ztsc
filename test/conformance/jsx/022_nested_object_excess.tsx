declare namespace JSX {
  interface Element {}
  interface IntrinsicElements {}
}

// An object literal passed as a JSX attribute value is fresh and gets the
// excess-property check against the target prop type — exactly like a call
// argument or assignment RHS. The container braces (`prop={{ … }}`) are
// transparent to the check.
type FilterProps = {
  value: string;
  options: string[];
  onValueChange: (v: string) => void;
};
declare function Drawer(props: {
  open: boolean;
  filter: FilterProps;
  // The empty object type `{}` accepts any property: no excess check.
  values?: {};
}): JSX.Element;

// `searchable` is not in FilterProps → TS2353 anchored at the property name.
const bad = (
  <Drawer
    open={true}
    filter={{
      value: 'a',
      options: ['b'],
      onValueChange: (v: string) => {},
      searchable: true,
    }}
  />
);

// A `{}`-typed prop never reports excess (react-i18next's `values?: {}`).
const ok = <Drawer open={true} filter={{ value: 'a', options: [], onValueChange: (v) => {} }} values={{ limit: 1, extra: 2 }} />;
