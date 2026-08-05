// tsc's `inferFromTypes` ends in an untargeted union-SOURCE rule: when the
// inference target is not itself a union or a type variable, a union source
// infers constituent by constituent. ztsc reached that pairing only through
// three identity rules — same generic origin, a discriminant, an index-shaped
// target — so a contextual type that is a union of UNRELATED named types
// inferred nothing and the callee's type parameter fell back to its default.
//
// The shape that motivates it is kysely's
// `OperandExpression<V> = Expression<V> | SelectQueryBuilderExpression<
// Record<string, V>>`, the contextual return type that
// `where<E extends ExpressionOrFactory<DB, TB, SqlBool>>` gives its factory
// argument. The `sql` tag is `<T = unknown>(…) => RawBuilder<T>`, so with
// nothing inferred `T` stayed `unknown` and `Expression<unknown>` was not
// accepted.

interface Expr<T> {
  readonly expressionType?: T | undefined;
}
interface Sqb<O> extends Expr<O> {
  readonly sqb: true;
}
interface RawBuilder<T> extends Expr<T> {
  readonly rb: true;
}

declare function raw<T = unknown>(x: number): RawBuilder<T>;

type Operand<V> = Expr<V> | Sqb<{ [k: string]: V }>;

// A union contextual RETURN type whose first constituent is the one that
// pairs. This is the `where(() => …)` shape.
declare function w1(e: () => Operand<boolean>): void;
w1(() => raw(1));

// The same union in a plain argument position.
declare function w2(x: Operand<boolean>): void;
w2(raw(1));

// A union whose pairing constituent is not first: the constituent that names
// no inference position of the target contributes nothing and the other one
// still answers.
interface Unrelated {
  readonly other: string;
}
declare function w3(x: Unrelated | Expr<number>): void;
w3(raw(1));

// A non-union contextual type is unchanged — this already worked.
declare function w4(e: () => Expr<boolean>): void;
w4(() => raw(1));

// A generic outer constraint over the same union: the arrow is contextually
// typed from `E`'s constraint, and its return context is still the union.
declare function w5<E extends Operand<boolean> | ((n: number) => Operand<boolean>)>(e: E): void;
w5(() => raw(1));

export {};
