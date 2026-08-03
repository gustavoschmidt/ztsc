// `[X] extends [Y]` — the idiom that switches a conditional's distributivity
// off — wraps both sides in a one-element tuple. Tuples relate element-wise,
// so the decidability question is EXACTLY the element's; asked of the tuples
// it is undecidable by construction and the whole chain defers.
//
// The element question here is settled by shape alone: no object type is
// assignable to a PRIMITIVE, whatever its free type parameters turn out to be.
// A class instance is not a string literal and not a template pattern, so the
// first two arms are definitely false for every substitution and the chain
// reaches its real last arm.
//
// This is kysely's `SelectFrom<DB, TB, TE>` skeleton. Left deferred, the chain
// exposed the apparent members of BOTH branches and a property lookup picked
// one for it — the first arm's `Q<DB, never, …>`, or the second arm's, which
// still carries the unbound `infer` binders of an extends clause that never
// matched.

interface DB {
  album: { id: string; a: number };
  asset: { id: string; b: number };
}

declare class Aliased<T extends string, A extends string> {
  private brand: T;
  alias: A;
}

type AliasOf<TE> = TE extends Aliased<any, infer A> ? A : never;
type From<D, TE> = { [C in keyof D | AliasOf<TE>]: C extends keyof D ? D[C] : never };
type Rec<K extends keyof any, V> = { [P in K]: V };

interface Q<D, TB extends keyof D, O> {
  all(): Q<D, TB, O & D[TB]>;
  run(): O;
}

type SelectFrom<D, TE> = [TE] extends [keyof D]
  ? Q<D, TE & keyof D, {}>
  : [TE] extends [`${infer T} as ${infer A}`]
    ? T extends keyof D
      ? Q<D & Rec<A, D[T]>, A & keyof (D & Rec<A, D[T]>), {}>
      : never
    : TE extends ReadonlyArray<infer _E>
      ? never
      : Q<From<DB, TE>, AliasOf<TE> & keyof From<DB, TE>, {}>;

declare function select<TE>(te: TE): SelectFrom<DB, TE>;

// The generic WRAPPER is the shape that used to fail: the check carries a free
// type parameter, so nothing about it is concrete until the call site binds it.
function query<T extends keyof DB & string>() {
  return select(null! as Aliased<T, T>);
}
function queryChained<T extends keyof DB & string>() {
  return select(null! as Aliased<T, T>).all();
}

export const direct = select(null! as Aliased<'album', 'album'>).all().run();
export const directId: string = direct.id;
export const wrapped = query<'album'>().all().run();
export const wrappedId: string = wrapped.id;
export const chained = queryChained<'album'>().run();
export const chainedA: number = chained.a;

// A string table expression still takes the FIRST arm — the carve-out only
// answers "definitely not", never "definitely yes".
export const byName = select('asset' as const).all().run();
export const byNameB: number = byName.b;

// Negatives: the reached arm's row type is the schema's, so a foreign member
// is still an error, and so is the wrong table's.
export const absent = wrapped.nope;
export const otherTable = wrapped.b;
