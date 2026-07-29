// A parameter whose type is an INTERSECTION must still hand its per-property
// contextual type down to an object-literal argument, so a fresh literal
// property value stays a literal and the callee's conditional return picks the
// right branch. `paramWantsLiteralCtx` only accepted `.object`/`.mapped`, so
// `elbowed: true` widened to `boolean` and `T extends true ? A : B` took the
// false branch.

type Opts = { x?: number; y?: number; strokeColor?: string };

declare function mk<T extends boolean>(
  o: { type: "arrow"; elbowed?: T; points?: number[] } & Opts,
): T extends true ? { kind: "elbow" } : { kind: "arrow" };

export const a: { kind: "elbow" } = mk({ type: "arrow", elbowed: true });
export const b: { kind: "elbow" } = mk({
  type: "arrow",
  x: 1,
  y: 2,
  points: [1],
  elbowed: true,
});
export const c: { kind: "arrow" } = mk({ type: "arrow", elbowed: false });
// Omitted: `T` stays its constraint `boolean` and the naked-type-param
// conditional distributes over `true | false`.
export const d: { kind: "elbow" } | { kind: "arrow" } = mk({ type: "arrow" });

// A nested intersection constituent (alias -> intersection) resolves the same.
type Inner = { elbowed?: boolean } & Opts;
declare function mk3<T extends boolean>(
  o: { kindTag: "k"; elbowed?: T } & Inner,
): T extends true ? { kind: "elbow" } : { kind: "arrow" };
export const e: { kind: "elbow" } = mk3({ kindTag: "k", elbowed: true });

// Control: the same signature with a plain (non-intersection) parameter was
// already correct and must stay so.
declare function mk2<T extends boolean>(
  o: { type: "arrow"; elbowed?: T; points?: number[] },
): T extends true ? { kind: "elbow" } : { kind: "arrow" };
export const f: { kind: "elbow" } = mk2({ type: "arrow", elbowed: true });

// Control: an intersection parameter with no literal-constrained type-parameter
// property must not start preserving literals that widen.
declare function plain(o: { n: number } & Opts): void;
export const g = plain({ n: 1, x: 2 });
