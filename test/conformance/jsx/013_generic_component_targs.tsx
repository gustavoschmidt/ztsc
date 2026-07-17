declare namespace JSX {
  interface Element {}
  interface IntrinsicElements {}
}

// Generic function components carrying explicit type arguments on the tag
// (`<Select<string> …>`). In a `.tsx` open tag this `<` is unambiguous.
declare function Select<T>(p: { onValueChange?: (v: T) => void; children?: any }): JSX.Element;
declare function Combobox<T, M>(p: { value?: T; multi?: M; children?: any }): JSX.Element;
declare function Box<T>(p: { value?: T }): JSX.Element;

// Shapes that must parse and type cleanly:
//   single arg + children, multi-arg + self-closing, self-closing single arg,
//   nested generic arg, and children without attributes.
const a = <Select<string> onValueChange={(v: string) => {}}>hi</Select>;
const b = <Combobox<number, true> value={1} multi={true} />;
const c = <Select<string> />;
const d = <Box<Array<string>> value={["x"]} />;
const e = <Select<string>>hi</Select>;

// The explicit type argument flows into the props type: with `T = string`,
// `value` is `string`, so a numeric attribute value is a TS2322.
const f = <Box<string> value={42} />;
