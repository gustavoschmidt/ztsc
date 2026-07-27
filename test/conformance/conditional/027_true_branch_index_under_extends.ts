// Inside a conditional's true branch the check type is known to be a subtype
// of the extends type (tsc models this with a substitution type). So the value
// of `K extends keyof Shapes ? Shapes[K] : Drawable` is readable as
// `Shapes[K & keyof Shapes]` and can be passed on — even though `K`'s own
// constraint (`"line" | "arrow" | "selection"`) has keys `Shapes` does not.
type Drawable = { d: number };
type Shapes = { line: Drawable[]; arrow: Drawable[] };
type ElementShape = Drawable[] | Drawable | null;

declare const cache: { set(k: string, v: ElementShape): void };

export const set = <T extends { type: "line" | "arrow" | "selection" }>(
  key: string,
  shape: T["type"] extends keyof Shapes ? Shapes[T["type"]] : Drawable,
) => {
  const widened: ElementShape = shape;
  cache.set(key, shape);
  return widened;
};

// Both branches still have to relate: the false branch is not covered by the
// substitution, so a target that only accepts the true branch is rejected —
// see the negatives case.
export const both = <K extends "line" | "selection">(
  v: K extends keyof Shapes ? Shapes[K] : Drawable,
): Drawable[] | Drawable => v;
