declare function use(x: unknown): void;

// Under the automatic JSX runtime (`jsx: "react-jsx"`) there is no global `JSX`
// namespace: it is an export of `<jsxImportSource>/jsx-runtime`. Intrinsic
// element attributes must still resolve through it, so a function-valued
// attribute is contextually typed by the target prop's signature instead of
// raising TS7006 on its parameters.
export const ok1 = <div onClick={(e) => use(e.x)} />;
export const ok2 = <input onChange={(e) => use(e.value)} />;

// The contextual type really flows: the parameter is the declared type.
export const ok3 = <input onChange={(e) => { const s: string = e.value; use(s); }} />;

// Fewer parameters than the target signature is allowed.
export const ok4 = <div onClick={() => use(0)} />;

// Non-function attributes are checked against the intrinsic's props too.
export const ok5 = <div className="a" />;

// A wrong explicit parameter type is still rejected.
export const bad1 = <div onClick={(e: string) => use(e)} />;

// A wrong attribute value type is still rejected.
export const bad2 = <div className={5} />;

// An attribute the intrinsic does not declare is still excess.
export const bad3 = <div notAProp="x" />;

// An unknown intrinsic tag is still an error.
export const bad4 = <nosuchtag />;
