// Negatives for key-set inference from a union's mapped constituent: `K` must
// come out as the source's own key set, not wider and not `never`.

type MkgState = { a: number; b: string };

declare function take<K extends keyof MkgState>(
  state:
    | ((prev: MkgState, props: { q: number }) => Pick<MkgState, K> | MkgState | null)
    | Pick<MkgState, K>
    | MkgState
    | null,
): [K];

export function forward<K2 extends keyof MkgState>(
  state:
    | ((prev: MkgState, props: any) => Pick<MkgState, K2> | MkgState | null)
    | Pick<MkgState, K2>
    | MkgState
    | null,
) {
  const k = take(state);
  const notNever: [never] = k;
  const notWide: ["a" | "b"] = k;
  return k;
}

// A key the state does not have is still rejected.
declare const foreign: { nope: number };
take(foreign);

// A source union whose mapped member carries a DIFFERENT state is not a key of
// this one.
type MkgOther = { z: boolean };
declare const other: Pick<MkgOther, "z"> | MkgOther | null;
take(other);
