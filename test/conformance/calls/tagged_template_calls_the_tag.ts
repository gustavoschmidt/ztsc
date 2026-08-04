// A tagged template is a CALL of the tag with the cooked-strings array and
// one argument per substitution, so its type is the tag's return type.
interface Raw<T> {
  v: T;
}

interface SqlTag {
  <T = unknown>(strings: TemplateStringsArray, ...params: readonly unknown[]): Raw<T>;
  ref<R = unknown>(name: string): Raw<R>;
}
declare const sqlTag: SqlTag;
declare function plainTag<T = unknown>(strings: TemplateStringsArray, ...params: readonly unknown[]): Raw<T>;

type Row = { a: string };

// Explicit type arguments (the parser routes these through an instantiation
// expression, which the tag call then reads).
export const t1: Raw<Row> = sqlTag<Row>`select 1`;
export const t2: Raw<Row> = plainTag<Row>`select 1`;
export const t3: Raw<Row> = sqlTag<Row>`select ${1} and ${"x"}`;

// No type argument: the parameter's DEFAULT.
export const t4: Raw<unknown> = sqlTag`select 1`;
export const t5: Raw<unknown> = plainTag`select 1`;

// Inference from a substitution.
declare function pick<T>(strings: TemplateStringsArray, value: T): T;
export const t6: number = pick`n = ${1}`;
export const t7: string = pick`s = ${"x"}`;

// An overloaded tag picks by arity.
declare function two(strings: TemplateStringsArray): number;
declare function two(strings: TemplateStringsArray, a: string): string;
export const t8: number = two`no subs`;
export const t9: string = two`one ${"sub"}`;

// (A NON-callable tag is deliberately left alone rather than reported: tsc
// files TS2349 there, ztsc answers `any`. An under-report, never a false
// positive — see `checkTaggedTemplate`.)
