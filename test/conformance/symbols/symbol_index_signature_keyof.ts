// `keyof { [k: symbol]: V }` is `symbol`, not `string | number`.
//
// ztsc stores a `symbol`-keyed index signature in the string-index slot, so
// everything that READS an index signature behaves as it did; `keyof` is the
// one consumer that has to tell them apart. Without it a `unique symbol` key
// was rejected by every `keyof S` parameter: nestjs-cls declares
// `interface ClsStore { [key: symbol]: any }` and immich's
// `config.repository.ts` calls `cls.get(CLS_ID)` / `cls.set(CLS_ID, cid)`
// with `declare const CLS_ID: unique symbol`.
interface Store {
  [key: symbol]: string;
}

declare const k: unique symbol;

declare function get<T extends Store>(store: T, key: keyof T): string;
declare const store: Store;
export const a: string = get(store, k);

// A plain `symbol` key works too, and a string one does not.
declare const anySym: symbol;
export const b: string = get(store, anySym);
export const c: string = get(store, 'x');

// Reading through the signature is unchanged.
export const d: string = store[k];

// A string-keyed signature still has key domain `string | number`…
interface SStore {
  [key: string]: string;
}
declare function sget<T extends SStore>(store: T, key: keyof T): string;
declare const sstore: SStore;
export const e: string = sget(sstore, 'x');
export const f: string = sget(sstore, 0);
export const g: string = sget(sstore, k);

// …and so does a shape that declares BOTH, where the two share one slot.
interface Both {
  [key: string]: string;
  [key: symbol]: string;
}
declare function bget<T extends Both>(store: T, key: keyof T): string;
declare const both: Both;
export const h: string = bget(both, 'x');

// A named property alongside the symbol signature is still a key.
interface Named {
  n: number;
  [key: symbol]: string;
}
declare const named: Named;
declare function nget<T extends Named>(store: T, key: keyof T): unknown;
export const i: unknown = nget(named, 'n');
export const j: unknown = nget(named, k);
