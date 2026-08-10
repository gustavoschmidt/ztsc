// The negative half of 121: matching a variadic target's fixed suffix from the
// END must not make the call accept arguments it should reject, and must not
// leave the variadic element itself uninferred.
type Schema = {devMode: boolean; themeKey?: 'day' | 'night'};

declare class Store<Scopes extends unknown[], S> {
  brand: [Scopes, S];
}
type StoreSchema<T> = T extends Store<any, infer U> ? U : never;
type StoreScopes<T> = T extends Store<infer S, any> ? S : never;

declare function use<
  T extends Store<any, any>,
  Key extends keyof StoreSchema<T>,
>(
  store: T,
  scopes: [...StoreScopes<T>, Key],
): StoreSchema<T>[Key];

declare const device: Store<[], Schema>;
declare const account: Store<[string], Schema>;

// A key the schema does not have.
use(device, ['nope']);

// The scope prefix is still type-checked: `account` needs a leading string.
use(account, ['devMode']);

// The inferred key is EXACT, so the result is `Schema['themeKey']` alone and
// not the union of every value type — reading it as `boolean` (the type of a
// different member) is rejected. With `Key` falling back to `keyof Schema`
// this line was silently accepted.
export const a: boolean = use(device, ['themeKey']);

// The variadic itself is inferred, and its elements are still checked.
declare function mid<S extends unknown[], L>(xs: [...S, L]): S;
export const b: [1, 2] = mid([1, 2, 3] as [1, 2, 3]);
export const c: [1, 2, 3] = mid([1, 2, 3] as [1, 2, 3]);

// Too few arguments to fill both fixed ends.
declare function both<H, S extends unknown[], L>(xs: [H, ...S, L]): [H, L];
both([1] as [1]);
