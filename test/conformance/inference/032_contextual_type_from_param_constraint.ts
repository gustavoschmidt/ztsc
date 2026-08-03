// A parameter that IS a still-un-inferred type variable contextually types its
// argument by the variable's CONSTRAINT, not by the placeholder standing in for
// it while inference runs. That is tsc's `getApparentTypeOfContextualType`,
// which takes the base constraint of a type variable before looking for a call
// signature.
//
// Every builder API declares its callback overload this way — kysely's
// `where<E extends ExpressionOrFactory<DB, TB, SqlBool>>(e: E)` is the shape —
// and without the constraint the arrow written for it gets no contextual
// signature at all, so each of its parameters is an implicit `any` (TS7006).
interface Expr<V> {
  readonly value: V;
}
interface Builder {
  make(k: string): Expr<boolean>;
  count(): Expr<number>;
}
type Factory = Expr<boolean> | ((b: Builder) => Expr<boolean>);

// A bare function-typed constraint...
declare function direct<E extends (b: Builder) => Expr<boolean>>(e: E): E;
export const a1 = direct((b) => b.make("x"));

// ...a UNION constraint with a callable constituent (the builder-API shape)...
declare function union<E extends Factory>(e: E): E;
export const a2 = union((b) => b.make("x"));

// ...and the same reached through a generic interface's method, where the
// method's own parameter is freshened as the receiver is instantiated.
interface QB<V> {
  where<E extends Expr<V> | ((b: Builder) => Expr<V>)>(e: E): QB<V>;
}
declare const qb: QB<boolean>;
export const a3 = qb.where((b) => b.make("x"));

// A parameter with no constraint keeps the old answer: nothing to contextually
// type with, so the parameter really is an implicit `any`.
declare function bare<E>(e: E): E;
export const a4 = bare((b) => b);

// Negatives: the contextual signature is REAL, so its parameter type is
// enforced and the return type is checked.
export const n1 = direct((b) => b.count());
export const n2 = union((b) => b.nope());
