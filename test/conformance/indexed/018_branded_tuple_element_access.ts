// Element access on a *branded* tuple/array — `[X, Y] & { _brand }` — reaches
// the tuple constituent, both as an expression and as an indexed-access type.
type Radians = number & { _brand: "radians" };
type LocalPoint = [Radians, Radians] & { _brand2: "local" };

declare const p: LocalPoint;

const ok0: Radians = p[0];
const ok1: Radians = p[1];
// @negative: the element type is not `string`
const bad0: string = p[0];
// @negative: `-p[0]` is a number, so it may not initialize a bigint
const neg: bigint = -p[0];

declare const i: number;
const okN: Radians = p[i];
// @negative
const badN: string = p[i];

// indexed-access type form
type E0 = LocalPoint[0];
declare const e0: E0;
const ok2: Radians = e0;
// @negative
const bad2: string = e0;

type EN = LocalPoint[number];
declare const en: EN;
const ok3: Radians = en;
// @negative
const bad3: string = en;

// A branded array behaves the same.
type Path = readonly Radians[] & { _brand3: "path" };
declare const q: Path;
const ok4: Radians = q[0];
// @negative
const bad4: string = q[0];

// An index signature in the intersection still works when no tuple/array is
// present.
type Bag = { [k: number]: boolean } & { tag: "bag" };
declare const b: Bag;
const ok5: boolean = b[0];
// @negative
const bad5: string = b[0];
