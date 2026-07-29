// Inferring into `Pick<S, K>` from a UNION source: the union's own mapped
// constituent pairs with the mapped target, so `K` comes from IT. Taking
// `keyof` of the whole union intersects every member's key set, and a member
// with no enumerable keys turns that into a symbolic intersection that cannot
// satisfy `K extends keyof S` — leaving `K` at its constraint, i.e. the full
// state, which rejects every forwarded partial update.

type MkState = { a: number; b: string };

declare function take<K extends keyof MkState>(
  state:
    | ((prev: MkState, props: { q: number }) => Pick<MkState, K> | MkState | null)
    | Pick<MkState, K>
    | MkState
    | null,
): [K];

// The forwarded-parameter face: the caller's own `K2` must come through.
export function forward<K2 extends keyof MkState>(
  state:
    | ((prev: MkState, props: any) => Pick<MkState, K2> | MkState | null)
    | Pick<MkState, K2>
    | MkState
    | null,
) {
  const k = take(state);
  const pair: [K2] = k;
  return pair;
}

// A source with no mapped constituent still uses the whole-union key set, so a
// void-returning updater infers `never` and `Pick<S, never>` accepts it.
declare function takeSmall<K extends keyof MkState>(
  state: Pick<MkState, K> | MkState | null,
): [K];
const voidUpdater = takeSmall(null);

// A partial object literal still infers its own keys.
const one = takeSmall({ a: 1 });
const oneKey: ["a"] = one;
