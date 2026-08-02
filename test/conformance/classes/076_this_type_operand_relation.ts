// Two deferred operators that differ only in WHICH instance their `this`
// marker was declared against must still relate: a polymorphic `this` relates
// through its apparent instance type, one level down as well as at top level.
//
// tsc never meets this pair — it resolves an interface reference's members
// with the reference itself as `thisArgument`, so both sides are concrete by
// comparison time — while ztsc keeps the marker until the access site. Without
// the normalization, `Std<Out<this>>` read off two different schema types
// compared as two unrelated deferred conditionals that print identically, and
// zod's `z.discriminatedUnion([...])` rejected every member it was given.
type Out<T> = T extends { _zod: { output: unknown } } ? T["_zod"]["output"] : unknown;

interface Std<O> {
  types: { output: O };
}

interface Base<O> {
  _zod: { output: O };
  "~standard": Std<Out<this>>;
}

interface Discriminable {
  _zod: { output: { tag: string } };
  "~standard": Std<Out<this>>;
}

interface Tagged extends Base<{ tag: "a"; n: number }> {}

declare function takesDiscriminable<T extends Discriminable>(items: T[]): T;

declare const tagged: Tagged;
export const ok = takesDiscriminable([tagged]);
export const okTag: "a" = ok._zod.output.tag;

// Direct assignment through the same member.
declare const d: Discriminable;
export const std: Std<{ tag: string }> = d["~standard"];

// Negative: normalizing through the apparent instance keeps the operand
// PRECISE, so an output that lacks the discriminant is still rejected.
interface Untagged extends Base<{ n: number }> {}
declare const untagged: Untagged;
export const bad: Std<{ tag: string }> = untagged["~standard"];
export const bad2: string = tagged["~standard"].types.output.n;
