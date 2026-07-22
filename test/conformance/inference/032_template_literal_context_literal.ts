// A fresh string literal keeps its literal type (rather than widening to
// `string`) when its contextual type is a template-literal or string-mapping
// type — tsc's isLiteralOfContextualType final mask (TemplateLiteral /
// StringMapping & isTypeAssignableTo). This lets a generic call whose parameter
// is constrained to such a type infer the type parameter to the literal (the
// react-hook-form `name: FieldPath<T>` field-name shape).

// Contextual type is a bare template-literal type: literal kept.
declare function pick<K extends `${string}`>(o: { key: K }): K;
const r1 = pick({ key: "alpha" });
const bad1: "" = r1; // TS2322 — proves r1 is "alpha", not string

// Dotted-path template union (react-hook-form Path shape): a matching literal
// is kept, so the type param infers to it.
declare function at<P extends `${string}` | `${string}.${string}`>(p: P): P;
const r2 = at("a.b");
const bad2: "" = r2; // TS2322 — proves r2 is "a.b"

// String-mapping context keeps a matching literal.
declare function up<S extends Uppercase<string>>(s: S): S;
const r3 = up("HELLO");
const bad3: "" = r3; // TS2322 — proves r3 is "HELLO"

// Negative control: a literal NOT matching the template pattern still fails the
// constraint (no spurious acceptance). `"noDot"` does not match
// `${string}.${string}`.
declare function dotted<P extends `${string}.${string}`>(p: P): P;
const r4 = dotted("noDot"); // TS2345 — "noDot" not assignable to the dotted pattern

// Negative control: a plain `string` context (not a template) still widens, so
// the annotation below is `string` and accepts any string (no error).
const wide: string = "x";
const okWide: string = wide;
