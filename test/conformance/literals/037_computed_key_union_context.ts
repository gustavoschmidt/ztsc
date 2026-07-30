// A computed-key member takes its contextual type from the contextual type's
// INDEX SIGNATURE, and that lookup has to map over the contextual type the way
// tsc's `getIndexTypeOfContextualType` does. Only a bare object used to be
// consulted, so `{ [id: string]: true } | undefined` — which is exactly what an
// OPTIONAL contextual property offers — gave the value no context at all and
// the fresh `true` widened to `boolean`. tsc: silent on everything below.
type Ids = { [id: string]: true };
declare const k: string;

// Union contexts: `| undefined` (optional position) and `| null`.
export const a: Ids | undefined = { [k]: true };
export const b: Ids | null = { [k]: true };

// Optional property of an optional parameter — the app shape.
declare function opt(x?: { ids?: Ids }): void;
opt({ ids: { [k]: true } });

// Intersection context.
export const c: Ids & { extra?: number } = { [k]: true };

// Numeric index signature through a union context.
type Nums = { [n: number]: 1 };
export const d: Nums | undefined = { [1 as number]: 1 };

// A union of two different index signatures: each constituent contributes, so
// the value is contextually `true | 1` and keeps its literal either way.
export const e: { [id: string]: true } | { [id: string]: 1 } = { [k]: true };
export const f: { [id: string]: true } | { [id: string]: 1 } = { [k]: 1 };

// Nested: the union context arrives through a spread object literal.
type State = { readonly ids: Readonly<Ids>; readonly zoom: number };
declare const st: State;
export const g: Partial<State> | null = {
  ...st,
  ids: { [k]: true },
};

// Through a generic call whose type parameter is inferred from the argument —
// the object literal is typed once against the constraint and again against the
// inferred type, and both passes have to agree.
interface Shape {
  name: string;
  make: (s: State) => { state?: Partial<State> | null; tag: "x" | "y" };
}
const reg = <T extends Shape>(v: T) => v;
export const h = reg({
  name: "h",
  make: (s) => {
    if (s.zoom > 1) {
      return {
        state: { ...s, ids: { [k]: true } },
        tag: "x",
      };
    }
    return { state: s, tag: "y" };
  },
});
