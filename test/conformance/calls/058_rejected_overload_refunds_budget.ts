// A rejected overload candidate must not spend the statement's
// instantiation budget on behalf of the candidates after it.
//
// `select`'s FIRST overload takes an array of `S extends W`, and its return
// type maps every member of that constraint through a template cross-product
// — so instantiating it with `S := W` costs more than the whole 250,000-node
// statement budget. The argument here is a CALLBACK, so that candidate is
// declined; but the budget it spent stayed spent, the callback overload
// beside it then instantiated to the truncation marker, read back as arity 0,
// and was rejected without ever being compared. The call reported TS2589 +
// TS2769 where tsc resolves it to the callback overload (the shape is
// kysely's `select`, immich `src/utils/database.ts:119`).
//
// Both must be clean, and `chk` must see the callback overload's return type.
type D = '0' | '1' | '2' | '3' | '4' | '5' | '6' | '7' | '8' | '9';
type W = `${D}${D}${D}`;
type W2 = `${D}${D}${D}`;

type Cross<K, U> = U extends string ? `${K & string}.${U}` | `${U}.${K & string}` : never;

interface Builder<O> {
  select<S extends W>(xs: S[]): Builder<O & { [K in S]: Cross<K, W2> }>;
  select<CB extends (b: Builder<O>) => { alias: string }>(cb: CB): Builder<O & { picked: CB }>;
  select<S extends W>(x: S): Builder<O & { [K in S]: Cross<K, W2> }>;
}

declare const qb: Builder<{}>;
const cb = (b: Builder<{}>) => ({ alias: 'x' });
export const out = qb.select(cb);
export const chk: Builder<{ picked: typeof cb }> = out;
