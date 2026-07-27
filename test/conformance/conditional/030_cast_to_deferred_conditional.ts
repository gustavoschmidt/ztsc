// The `as`-cast overlap test (TS2352) against a DEFERRED conditional type.
//
// A generic function that presents an overload set as one conditional return
// type computes the result structurally and casts it to that return type. The
// conditional cannot be resolved at the cast site, so ztsc's comparable
// relation had no arm for it and rejected every such cast. tsc compares against
// the conditional's default constraint — the union of its two branches — and
// distributes over it existentially.

type E = { kind: "e" };
type F = { kind: "f" };

// POSITIVE (must NOT error) --------------------------------------------------

// The idiom: compute, then cast to the declared conditional return type.
export const pick = <T extends E | E[]>(
  element: T,
): T extends E[] ? E[] : E | null => {
  const arr: E[] = [];
  return (Array.isArray(element) ? arr : arr[0] || null) as T extends E[]
    ? E[]
    : E | null;
};

// Overlapping the TRUE branch alone is enough.
export const onlyTrue = <T extends boolean>(): T extends true ? E : F => {
  const e: E = { kind: "e" };
  return e as T extends true ? E : F;
};

// Overlapping the FALSE branch alone is enough.
export const onlyFalse = <T extends boolean>(): T extends true ? E : F => {
  const f: F = { kind: "f" };
  return f as T extends true ? E : F;
};

// The conditional on the SOURCE side of the cast.
declare const src: E extends E ? E : never;
export const fromCond = src as E | F;

// A literal-keyed selector, the `getKey<T extends "a" | "b">` shape.
declare const raw: string | number | undefined;
export const sel = <T extends "a" | "b">(): T extends "a" ? number : string =>
  raw as T extends "a" ? number : string;

// NEGATIVE (must error) ------------------------------------------------------

// Overlapping NEITHER branch is still a mistake.
export const bad = <T extends boolean>() => {
  const s = "x";
  return s as T extends true ? E : F; // TS2352
};

// Regression: a non-conditional non-overlap still errors.
declare const o: { q: number };
export const bad2 = o as number | boolean; // TS2352
