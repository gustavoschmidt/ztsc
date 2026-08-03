// A distributive conditional used as a mapped type's value, over the mapped
// source's own property type: `{ [K in keyof O]: F<O[K]> }`.
//
// It is instantiated twice. The first pass binds `F`'s parameter to the still
// generic `O[K]` and defers; by the second — binding `K` to a key — the check
// is an indexed access, not a bare type parameter, so distribution has to
// recognise it by the check EXPRESSION rather than by a symbol. Getting that
// wrong does not just skip the distribution: the branches are instantiated
// with the whole union in the check's place, so a conditional NESTED in a
// branch answers for the union rather than for the constituent, and its answer
// is unioned in beside the correct one.
//
// kysely's `ShallowDehydrateObject` is the shape in the wild — a
// `string | null` column picked up a spurious
// `ShallowDehydrateValue<unknown>[]` arm from the nested
// `T extends (infer U)[] | null | undefined` test, which the `| null` half
// matches with `U` unbound.

type F<T> = T extends null | undefined ? 'A' : T extends (infer U)[] | null | undefined ? ['B', U] : 'C';
type M<O> = { [K in keyof O]: F<O[K]> };

// Standalone, the parameter is still bare and the distribution is the ordinary
// one.
const s1: 'A' | 'C' = null! as F<string | null>;
const s2: ['B', string] = null! as F<string[]>;

// Through the mapped type the answers have to be identical.
type Mapped = M<{ nullable: string | null; plain: string; list: string[]; listOrNull: string[] | null }>;
declare const m: Mapped;
const m1: 'A' | 'C' = m.nullable;
const m2: 'C' = m.plain;
const m3: ['B', string] = m.list;
const m4: 'A' | ['B', string] = m.listOrNull;

// A NON-distributive conditional (the check is wrapped) still sees the whole
// union in the mapped type, exactly as it does standalone.
type G<T> = [T] extends [null | undefined] ? 'A' : 'C';
type N<O> = { [K in keyof O]: G<O[K]> };
declare const n: N<{ nullable: string | null; onlyNull: null }>;
const n1: 'C' = n.nullable;
const n2: 'A' = n.onlyNull;

// And a nested distributive conditional whose check is a DIFFERENT expression
// keeps its own distribution.
type H<T, S> = T extends string ? (S extends number ? 'both' : 'first') : 'neither';
type P<O> = { [K in keyof O]: H<O[K], number | string> };
declare const p: P<{ a: string; b: boolean }>;
const p1: 'both' | 'first' = p.a;
const p2: 'neither' = p.b;

export { s1, s2, m1, m2, m3, m4, n1, n2, p1, p2 };
