// `infer` against an array pattern has to look inside an *intersection*
// source. A branded tuple — `[Point, Point] & { _brand: "segment" }`, the
// standard nominal-array idiom — is still an array, and its element type lives
// in the array constituent. Matching only the top-level kind found nothing and
// left the infer var at its `unknown` fallback, so `segs.flat()` came back
// `unknown[]`.
type Point = [number, number] & { _brand: "point" };
type Segment = [Point, Point] & { _brand: "segment" };

type El<A> = A extends ReadonlyArray<infer I> ? I : "not-an-array";

export const a: Point = null! as El<Segment>;

// Array (not tuple) constituent.
type Branded = string[] & { _brand: "b" };
export const b: string = null! as El<Branded>;

// The brand object alone contributes nothing, so a brand-only intersection
// still takes the false branch.
type NotArray = { x: number } & { _brand: "n" };
export const c: "not-an-array" = null! as El<NotArray>;

// The shape this came from.
declare const segs: Segment[];
export const flat: Point[] = segs.flat();
