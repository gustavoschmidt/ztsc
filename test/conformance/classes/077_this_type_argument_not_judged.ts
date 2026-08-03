// A polymorphic `this` passed as a type ARGUMENT is a type variable, so the
// written-type-argument constraint gate (TS2344) must stay silent about it —
// the same policy it already applies to a bare type parameter. The question
// "does `this` satisfy this bound" is decided over a self-reference whose own
// parameters are still their own bounds, i.e. about the checker's resolution
// rather than about the code.
//
// drizzle-orm writes `NotNull<this>` / `$Type<this, T>` on nearly every
// column-builder method; judging them produced 45 false TS2344s.
interface Base {
  readonly _: { kind: string };
}
type NotNull<T extends Base> = T & { _: { notNull: true } };
type Retype<T extends Base, V> = T & { _: { data: V } };

declare class Builder<TConfig extends { kind: string }> implements Base {
  readonly _: { kind: string } & TConfig;
  notNull(): NotNull<this>;
  retype<V>(): Retype<this, V>;
}

declare const b: Builder<{ kind: "int" }>;
export const n = b.notNull();
export const r = b.retype<number>();
// The instance still carries its own members through the intersection.
export const k: string = n._.kind;
export const t: true = n._.notNull;

// A concrete argument is still judged — the gate is silent about `this`, not
// about everything.
export type Bad = NotNull<{ nope: 1 }>;
