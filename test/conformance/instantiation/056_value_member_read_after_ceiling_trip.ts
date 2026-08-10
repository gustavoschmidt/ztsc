// A property READ off a generic reference, taken after this checker has
// already run out of instantiation room once.
//
// `propertyTypeOf` answers such a read by materializing the receiver's WHOLE
// member table (`resolveStructural` -> `expandRef`) and looking one name up in
// it. tsc does not: `getTypeOfPropertyOfType` asks `getPropertyOfType` for a
// single symbol out of the table `createInstantiatedSymbolTable` built from
// `(target, mapper)` pairs — the member types are not computed — and only then
// runs `getTypeOfSymbol` on that one symbol. ztsc now mirrors that, but only
// once `inst_ceiling_trips != 0`, because on a program that never runs out of
// room the whole-table expansion is a prepayment every later reader lives off
// (see `lazyIndexedProp`, and prof.zig for the two measurements that made the
// gate mandatory).
//
// The first statement here is the ceiling trip that opens the route — a
// self-referential-depth generic that tsc reports TS2589 on as well, so the
// case stays oracle-faithful. Everything after it is read through the lazy
// single-member path, and every answer has to be exactly what the whole-table
// expansion would have given: the same type, the same optionality, the same
// polymorphic-`this` substitution, and the same failures.
//
// This pins the route's ANSWERS, not the saving that motivates it: a
// hand-written table cheap enough to write here is also cheap enough for the
// eager path to finish, so the case passes either way. The saving needs a
// member table whose substitution genuinely exceeds a statement's 250,000-node
// budget, and every synthetic tried for one stayed cheap because ztsc defers
// alias references and mapped types at instantiation — four shapes (an inline
// homomorphic mapped over a wide template-literal key set, the same behind an
// alias, a recursive conditional alias in the value position, and a nested
// distributive `Cross<Cross<T, W3>, W2>`) all cost under 13,000 visits with
// zero trips. It is pinned by the social-app app gate, where
// `state/persisted/schema.ts`'s `schema.safeParse(objData)` spends the whole
// budget on `ZodObject`'s table and reads one member out of it.
type Deep<T> = [[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[T]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]];
const tripped: string = 0 as unknown as Deep<number>;

interface Box<T, U> {
  value: T;
  pair: [T, U];
  opt?: U;
  make(): Box<U, T>;
  self(): this;
  nested: Box<U, T>;
}

declare const b: Box<'x', 42>;

export const v: 'x' = b.value;
export const p: ['x', 42] = b.pair;
export const o: 42 | undefined = b.opt;
export const m: Box<42, 'x'> = b.make();
export const s: Box<'x', 42> = b.self();
export const n: Box<42, 'x'> = b.nested;
export const inner: 42 = b.nested.value;

// The member is genuinely absent, so the lazy lookup must fall through to the
// ordinary not-found path and report, not answer `any`.
// @ts-expect-error
b.missing;

export const t = tripped;
