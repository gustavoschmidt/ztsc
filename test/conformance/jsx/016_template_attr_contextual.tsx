declare namespace JSX {
  interface Element {}
  interface IntrinsicElements {}
}

// A template-literal-typed prop. A template-literal *expression* attribute
// value is contextually typed by it and keeps its template structure instead
// of widening to `string`.
type IconifyPath = `${string}:${string}`;
type IconName = 'add' | 'home' | IconifyPath;
declare function Icon(props: { name: IconName }): JSX.Element;

declare const s: string;

// Template expression matching the `${string}:${string}` pattern — no error.
const ok = <Icon name={`material-symbols:${s}`} />;

// A plain (non-template) string value is still just `string` and is rejected.
const bareString = <Icon name={s} />;

// A non-matching string literal is rejected.
const literal = <Icon name="nope" />;
