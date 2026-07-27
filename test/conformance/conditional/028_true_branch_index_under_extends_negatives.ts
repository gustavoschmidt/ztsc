// Reading a conditional's true branch under its extends constraint must not
// make the whole conditional assignable to whatever the TRUE branch alone
// fits: the false branch still has to relate too.
type Drawable = { d: number };
type Shapes = { line: Drawable[]; arrow: Drawable[] };

export const onlyTrue = <K extends "line" | "selection">(
  v: K extends keyof Shapes ? Shapes[K] : Drawable,
): Drawable[] => v; // false branch is `Drawable`, not `Drawable[]`

export const onlyFalse = <K extends "line" | "selection">(
  v: K extends keyof Shapes ? Shapes[K] : Drawable,
): Drawable => v; // true branch is `Drawable[]`, not `Drawable`

// The substitution narrows the check type, it does not erase it: indexing with
// a key outside the extends type is still out of bounds.
export const wrong = <K extends "line" | "selection">(
  v: K extends "line" ? Shapes[K] : Drawable,
): Drawable[] => v;
