// tsc reads a mapped type's MODIFIERS TYPE through `getApparentType`, so for a
// `Pick<T, …>` written inside a generic function the modifiers come from `T`'s
// CONSTRAINT. ztsc's modifiers-type preservation only accepted an object /
// intersection / union, so a bare type parameter fell through and every picked
// property read as required — including the one the constraint declares
// optional (spurious TS2741).
type Elem = { id: string; x: number; customData?: { tag: string } };
type Ctor = Required<Omit<Elem, "customData">> & { customData?: Elem["customData"] };

export const pick = <T extends Ctor>(e: T) => {
  // `customData` stays optional, so the literal may omit it.
  const base: Pick<T, keyof Elem> = { id: e.id, x: e.x };
  return base;
};

// A required property of the constraint is still required.
export const missRequired = <T extends Ctor>(e: T) => {
  const base: Pick<T, keyof Elem> = { id: e.id };
  return base;
};

// `readonly` carries the same way.
type RO = { readonly a: string; b: number };
export const ro = <T extends RO>(e: T) => {
  const base: Pick<T, keyof RO> = { a: e.a, b: e.b };
  base.a = "x";
  base.b = 1;
  return base;
};

// The map's OWN modifiers still apply on top: `-?` makes everything required.
type AllReq<S, K extends keyof S> = { [P in K]-?: S[P] };
export const stripOptional = <T extends Ctor>(e: T) => {
  const base: AllReq<T, keyof Elem> = { id: e.id, x: e.x };
  return base;
};

// `+?` makes everything optional even where the constraint is required.
type AllOpt<S, K extends keyof S> = { [P in K]+?: S[P] };
export const addOptional = <T extends Ctor>(e: T) => {
  const base: AllOpt<T, keyof Elem> = {};
  return base;
};

// A NON-generic `Pick` was already right; regression guard.
export const concrete: Pick<Elem, "id" | "customData"> = { id: "a" };

// An unconstrained type parameter has no modifiers to read; the picked props
// come from an empty key set, so the literal must be empty.
export const bare = <T>(_e: T) => {
  const base: Pick<T, never> = {};
  return base;
};
