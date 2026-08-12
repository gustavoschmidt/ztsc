// tsc's `typeRelatedToDiscriminatedType` does not compare a source
// discriminant constituent against the member's raw property type — it calls
// `propertyRelatedTo`, whose target side is
// `addOptionality(getNonMissingTypeOfSymbol(targetProp), false,
// targetIsOptional)`. An OPTIONAL member property therefore accepts
// `undefined` on top of its declared tag.
//
// An all-optional source carries `undefined` in its own discriminant, so
// without that the `undefined` constituent is covered by no member and the
// whole split declines — even though every real tag is covered. This is
// excalidraw's `Delta.create(deleted, inserted, stripIrrelevantProps)`:
// `Partial<Omit<Partial<Ordered<Element>>, …>>` against
// `Partial<Ordered<ExcalidrawElement>>`, where the target splits `type`
// across thirteen constituents and the source is the single
// `Omit`-of-the-union object whose `type` is the whole tag union.
type A = { kind: "a"; x: number };
type B = { kind: "b"; y: number };
type U = A | B;

declare let target: Partial<U & { index: number }>;

// the tag union alone: covered member by member, no `undefined` in play
declare const plain: { kind?: "a" | "b" };
target = plain;

// …and with the `undefined` an all-optional source's discriminant carries
declare const withUndef: { kind?: "a" | "b" | undefined };
target = withUndef;

// the shape the mapped types actually produce
declare const mapped: Partial<Omit<Partial<U & { index: number }>, "nope">>;
target = mapped;

export { target };
