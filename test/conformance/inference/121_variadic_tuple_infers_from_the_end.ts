// tsc's `inferFromTupleTypes` does not pair two tuples from index 0. It pairs
// the target's FIXED PREFIX from the start, its FIXED SUFFIX from the end, and
// gives whatever is left between them to the variadic element — `startLength`
// and `endLength` in that function. Index-for-index pairing is what the rule
// reduces to when the target has no variadic at all, so it is only observable
// when fixed elements follow one.
//
// `[...Scopes, Key]` is that shape, and it is social-app's storage layer:
// `useStorage(device, ['themeKey'])` with `Scopes` reducing to `[]`. Paired
// from index 0 the variadic swallowed `'themeKey'`, `Key` was never inferred
// and fell back to its constraint `keyof Schema` — so the read came back as
// the union of every value type in the schema and the setter rejected every
// value. Writing the spread out (`[...[], Key]`) hides it: `makeTuple`
// flattens a rest element whose type is already a tuple, so the declaration
// normalizes to `[Key]` before inference ever sees it.
type Schema = {
  devMode: boolean;
  fontScale: '-2' | '-1' | '0' | '1' | '2';
  themeKey?: 'day' | 'night';
};

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
): [StoreSchema<T>[Key] | undefined, (v: StoreSchema<T>[Key]) => void];

declare const device: Store<[], Schema>;
declare const account: Store<[string], Schema>;

// Empty variadic: the single argument element is the SUFFIX, not the prefix.
const [theme, setTheme] = use(device, ['themeKey']);
export const a: 'day' | 'night' | undefined = theme;
export const b: (v: 'day' | 'night' | undefined) => void = setTheme;

const [dev] = use(device, ['devMode']);
export const c: boolean | undefined = dev;

// Non-empty variadic: the prefix is matched from the start and the suffix
// still from the end.
const [scale] = use(account, ['acct', 'fontScale']);
export const d: '-2' | '-1' | '0' | '1' | '2' | undefined = scale;

// A bare type parameter in the variadic slot, inferred from the same call.
declare function tail<S extends unknown[], L>(xs: [...S, L]): L;
export const e: 3 = tail([1, 2, 3] as [1, 2, 3]);
export const f: 1 = tail([1] as [1]);

// A leading fixed element ahead of the variadic.
declare function both<H, S extends unknown[], L>(xs: [H, ...S, L]): [H, L];
export const g: [1, 4] = both([1, 2, 3, 4] as [1, 2, 3, 4]);

// The variadic still collects the middle.
declare function mid<S extends unknown[], L>(xs: [...S, L]): S;
export const h: [1, 2] = mid([1, 2, 3] as [1, 2, 3]);

// A rest element LAST is untouched by the rule (no fixed suffix).
declare function head<H, S extends unknown[]>(xs: [H, ...S]): H;
export const i: 1 = head([1, 2, 3] as [1, 2, 3]);
