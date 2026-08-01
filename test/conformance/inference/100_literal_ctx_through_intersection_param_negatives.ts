// Negatives for 099: keeping the literal through an intersection parameter
// must still REPORT when the conditional return really is the other branch,
// and must not start accepting a widened `boolean`.

type Opts = { x?: number; y?: number };

declare function mk<T extends boolean>(
  o: { type: "arrow"; elbowed?: T } & Opts,
): T extends true ? { kind: "elbow" } : { kind: "arrow" };

// `elbowed: true` => elbow, so the arrow annotation is an error.
export const a: { kind: "arrow" } = mk({ type: "arrow", elbowed: true });
// `elbowed: false` => arrow, so the elbow annotation is an error.
export const b: { kind: "elbow" } = mk({ type: "arrow", elbowed: false });
// omitted => `T` falls back to its constraint and the conditional distributes.
export const c: { kind: "elbow" } = mk({ type: "arrow" });

// A widened `boolean` variable must NOT select the true branch.
declare const flag: boolean;
export const d: { kind: "elbow" } = mk({ type: "arrow", elbowed: flag });

// Excess-property checking through the intersection parameter: `bogus` is
// declared by no constituent of `{ type; elbowed? } & Opts`, so it is TS2353
// (tsc's `isKnownProperty` recursing through a UnionOrIntersection target).
export const e = mk({ type: "arrow", elbowed: true, bogus: 1 });
