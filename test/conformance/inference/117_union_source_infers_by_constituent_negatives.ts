// The negative control for `union_return_context_infers_by_constituent.ts`:
// what a union SOURCE still must not infer.

interface Expr<T> {
  readonly expressionType?: T | undefined;
}
interface RawBuilder<T> extends Expr<T> {
  readonly rb: true;
}
declare function raw<T = unknown>(x: number): RawBuilder<T>;

// No constituent names an inference position of the target, so nothing is
// inferred, `T` keeps its `unknown` default and the assignment is rejected —
// the pre-existing behaviour, which the narrowed gate must preserve.
interface Other {
  readonly other: string;
}
declare function n1(x: Other | { readonly another: number }): void;
n1(raw(1));

// A constituent that pairs still has to AGREE: the inferred `string` is not a
// `boolean`.
declare function n2(x: Expr<string> | Other): void;
const bad: Expr<boolean> = raw(1) as RawBuilder<boolean>;
void bad;
n2(bad);

export {};
