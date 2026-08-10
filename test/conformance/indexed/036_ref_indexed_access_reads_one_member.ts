// THE CONTRACT `lazyIndexedProp` HAS TO MEET. A type-level `Ref["name"]` may
// be answered by substituting ONE member of the reference's table instead of
// materializing the whole thing (tsc's `getIndexedAccessType` ->
// `getPropertyOfType` -> `getTypeOfSymbol` on an instantiated symbol), and the
// single-member answer has to equal the one the expansion would have held. So
// this pins each thing the expansion carries: an own member, an INHERITED one,
// an OPTIONAL one (which widens with `undefined`), a member whose type mentions
// the class's own polymorphic `this`, a member off a heritage clause, and a
// member reached through an index signature.
//
// It runs on the EAGER path, which is the point: the lazy route only opens once
// a checker has run out of instantiation room (`inst_ceiling_trips`), and a
// case that spends 250,000 node visits reports a TS2589 that tsc — with twenty
// times the budget — does not, so no oracle-faithful fixture can enter it. See
// prof.zig, which records four other attempts at the same thing. The lazy half
// is pinned by the social-app gate; this is the answer it must reproduce.
//
// (A genuinely ABSENT key is deliberately not here: ztsc answers `unknown` for
// one and does not raise tsc's TS2339 on the written access, on either route —
// see `checkIndexedAccessIndex`'s decidable-shape restriction. That gap is
// unchanged by this route and pinning it here would encode it twice.)
//
// The shape it exists for is zod's: `z.infer<typeof schema>` is
// `(typeof schema)['_output']`, and `ZodType`'s fluent API gives every schema
// forty members that each name a wrapper of `this`. Reading the whole table to
// answer one key spent the entire instantiation budget on social-app's
// ~40-property `z.object({…})`, so `z.infer` came back `any` and every
// `persisted.get(k)` callback in the app went implicit-any.
declare class Base<O> {
  readonly _out: O;
  opt?: O;
  self(): this;
  wrapped(): Box<this>;
}
declare class Box<X> extends Base<{boxed: X}> {
  readonly _box: X;
}
declare class Leaf<T> extends Base<{leaf: T}> {
  readonly extra: T[];
}

type Shape = {a: string; b: number};

// Own member of the base, through a derived reference.
export const own: {leaf: Shape} = null! as Leaf<Shape>['_out'];
// Own member of the derived class itself.
export const derived: Shape[] = null! as Leaf<Shape>['extra'];
// An OPTIONAL member widens with `undefined`.
export const optional: {leaf: Shape} | undefined = null! as Leaf<Shape>['opt'];
// A member whose type is the polymorphic `this` reads as the receiver.
export const thisMember: () => Leaf<Shape> = null! as Leaf<Shape>['self'];
export const thisWrapped: () => Box<Leaf<Shape>> = null! as Leaf<Shape>['wrapped'];
// ... and one more hop, so the wrapper's own table is read the same way.
export const nested: {boxed: Leaf<Shape>} = null! as Box<Leaf<Shape>>['_out'];

// An interface reference, with the member coming from a heritage clause.
interface IBase<T> {
  v: T;
}
interface IDerived<T> extends IBase<T[]> {
  w: T;
}
export const iOwn: string = null! as IDerived<string>['w'];
export const iInherited: string[] = null! as IDerived<string>['v'];

// A reference with an index signature answers an unlisted key off it.
interface Bag<T> {
  named: T;
  [k: string]: T;
}
export const bagNamed: number = null! as Bag<number>['named'];
export const bagIndexed: number = null! as Bag<number>['whatever'];

// Negatives: each of the above really is the type claimed.
export const bad1: string = null! as Leaf<Shape>['_out'];
export const bad2: {leaf: Shape} = null! as Leaf<Shape>['opt'];
export const bad3: number = null! as IDerived<string>['v'];
export const bad4: string = null! as Bag<number>['whatever'];
