declare namespace JSX {
  interface Element {}
  interface IntrinsicElements {}
}

// An enum MEMBER inside an object/array-literal ATTRIBUTE, feeding a
// string-constrained type parameter. Two halves:
//
//   1. The attribute value was typed context-free during JSX type-argument
//      inference, so the fresh enum member widened to the whole enum before
//      unification saw it (`inferTypeArgs`' Phase 1 already contextually types
//      an object-literal ARGUMENT under the same `paramWantsLiteralCtx` gate).
//   2. tsc gives a string enum member `TypeFlags.StringLiteral | EnumLiteral`,
//      so the type-VARIABLE rule of `isLiteralOfContextualType` (`T extends
//      string` is a literal context) keeps it. ztsc models an enum member as
//      its own kind, so it did not match the "string literal" test and widened
//      anyway.
//
// Together they made `T` infer as the whole enum, and a handler typed for the
// two-member subset was then rejected (TS2322).

enum Breed {
  Nellore = "NELLORE",
  NelloreCross = "NELLORE_CROSS",
  Angus = "ANGUS",
}

declare const Seg: <T extends string>(props: {
  options: { value: T; label: string }[];
  value: T;
  onChange: (v: T) => void;
}) => JSX.Element;

declare const breed: Breed.Nellore | Breed.NelloreCross;
declare const setBreed: (v: Breed.Nellore | Breed.NelloreCross) => void;

export const a = (
  <Seg
    options={[
      { value: Breed.Nellore, label: "a" },
      { value: Breed.NelloreCross, label: "b" },
    ]}
    value={breed}
    onChange={setBreed}
  />
);

// The options alone carry the same evidence.
declare const S2: <T extends string>(props: {
  options: { value: T }[];
  onChange: (v: T) => void;
}) => JSX.Element;

export const b = <S2 options={[{ value: Breed.Nellore }]} onChange={setBreed} />;

// NEGATIVE: `T` really is the narrow member union, so a handler for a member
// OUTSIDE it is rejected.
declare const setAngus: (v: Breed.Angus) => void;
export const c = <S2 options={[{ value: Breed.Nellore }]} onChange={setAngus} />;
