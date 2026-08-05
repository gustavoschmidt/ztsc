// An array literal whose contextual type is still a type VARIABLE takes its
// per-element contextual type from that variable's CONSTRAINT — tsc's
// `getApparentTypeOfContextualType`, which maps an instantiable contextual type
// to its base constraint before `getContextualTypeForElementExpression` reads
// an element off it.
//
// `checkArrayLiteral` already looked through the constraint to decide TUPLE
// context; the plain-array branch did not, so `f<T extends Name[]>(xs: T)`
// called with `['a']` checked the element with no contextual type at all and
// `'a'` widened to `string`. Writing `['a'] as const`, or the type argument by
// hand, was already correct — which is the tell.
//
// Found on immich: kysely's `selectFrom<TE extends TableExpressionOrList<DB,
// TB>>(from: TE)` inferred `TE = string[]` for `db.selectFrom(['person'])`, and
// `From<DB, string>` then collapsed the whole schema to `{ [x: string]: <one
// table> }`, so the query builder came back as a union with one constituent per
// table and the row type of `person.getByName` was `{}`.

type Name = 'a' | 'b' | 'c';

declare function pick<T extends readonly Name[]>(xs: T): T[number];
export const one: 'a' = pick(['a']);
export const two: 'a' | 'b' = pick(['a', 'b']);

// A mutable-array constraint behaves the same.
declare function pickMut<T extends Name[]>(xs: T): T[number];
export const three: 'a' = pickMut(['a']);

// The constraint may be a UNION of a single value and an array of them — the
// shape kysely's `TableExpressionOrList` has.
declare function pickOrList<T extends Name | readonly Name[]>(xs: T): T;
export const four: readonly ['a'] | 'a'[] = pickOrList(['a']);

// A nested generic in the constraint still resolves through it.
type Wrap<S> = readonly S[];
declare function pickWrapped<T extends Wrap<Name>>(xs: T): T[number];
export const five: 'b' = pickWrapped(['b']);

// Negative control (a): an UNCONSTRAINED type parameter is not a literal
// context, so the element widens exactly as before.
declare function loose<T>(xs: T): T;
export const six: string[] = loose(['a']);
export const sixBad: 'a'[] = loose(['a']);

// Negative control (b): a constraint whose element type is the bare primitive
// is a widening context for a plain value but the type-VARIABLE rule still
// keeps the literal (tsc's `isLiteralOfContextualType` final clause), so this
// one infers `'a'[]` and NOT `string[]`.
declare function strs<T extends string[]>(xs: T): T[number];
export const seven: 'a' = strs(['a']);

// Negative control (c): the element's own annotation still wins over the
// contextual read.
const widened: string = 'a';
export const eight: string = pick([widened as Name]);
