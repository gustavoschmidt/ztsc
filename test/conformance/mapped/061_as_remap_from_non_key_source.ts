// A key-remapped mapped type whose SOURCE constituents are not usable as
// property names: an object type and a function type. The `as` clause is
// what names the property, so the key itself may be any type at all (tsc's
// addMemberForKeyType). kysely's `Selection<DB, TB, SE>` is this shape —
// `{ [E in SE as ExtractAlias<E>]: ExtractType<E> }` over a select
// expression that may be a column string, an aliased expression object, or
// an `(eb) => …` callback.
interface Aliased<O, A extends string> {
  readonly o: O;
  readonly a: A;
}

type ExtractAlias<SE> = SE extends string
  ? SE
  : SE extends Aliased<any, infer EA>
    ? EA
    : SE extends (eb: any) => Aliased<any, infer EA>
      ? EA
      : never;

type ExtractType<SE> = SE extends Aliased<infer O, any>
  ? O
  : SE extends (eb: any) => Aliased<infer O, any>
    ? O
    : SE;

type Selection<SE> = { [E in SE as ExtractAlias<E>]: ExtractType<E> };

// object source
declare const fromObject: Selection<Aliased<number, 'count'>>;
export const n: number = fromObject.count;

// function source
declare const fromCallback: Selection<(eb: unknown) => Aliased<string, 'name'>>;
export const s: string = fromCallback.name;

// union of a string key, an object and a callback
declare const mixed: Selection<'raw' | Aliased<number, 'count'> | ((eb: unknown) => Aliased<string, 'name'>)>;
export const r: 'raw' = mixed.raw;
export const n2: number = mixed.count;
export const s2: string = mixed.name;

// a source constituent the `as` clause maps to `never` is filtered out
declare const filtered: Selection<Aliased<number, 'count'> | { nope: 1 }>;
export const n3: number = filtered.count;
export const bad = filtered.nope;
