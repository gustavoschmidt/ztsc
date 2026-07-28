// A homomorphic mapped type over an INTERSECTION whose constituents include a
// tuple or an array must keep that half. The intersection arm collects named
// props only, so `Mutable<readonly [number, number] & { _brand }>` — a branded
// point, the excalimath idiom — came out as just `{ _brand }`: no `length`, no
// element access, and every branded-point argument was a spurious TS2345.
//
// DOCUMENTED DIVERGENCE: tsc materializes the full apparent member set of the
// intersection instead (a numeric index signature plus every `Array.prototype`
// member), which is *not* a tuple, so tsc rejects `Mutable<Point>` where a bare
// `[number, number]` is wanted. ztsc keeps the tuple/array shape: the same
// relation for every real use, a far smaller type, and it prints as the source
// does. The one-way cost is an under-report on that (rare) rejection —
// under-report over false positive, as elsewhere.
type Mutable<T> = { -readonly [P in keyof T]: T[P] };
type Point = readonly [number, number] & { _brand: "point" };
type Boxes = readonly { id: string }[] & { _brand: "boxes" };

declare function wantPoint(p: Point): void;

export const f = (p: Mutable<Point>) => {
  const first: number = p[0]; // the tuple half survives the map
  const n: number = p.length;
  const b: "point" = p._brand; // and so does the object half
  return [first, n, b];
};

// `-readonly` really is applied to the elements: the mapped point is mutable
// where the source is not.
export const g = (p: Mutable<Point>) => {
  p[0] = 1;
  return p;
};

// the mapped point is still structurally a point.
export const i = (p: Mutable<Point>) => wantPoint(p);

// negative control: a bare tuple is not — it lacks the brand.
export const j = (p: [number, number]) => wantPoint(p); // TS2345

// an array constituent keeps its array-ness the same way.
export const k = (p: Mutable<Boxes>) => {
  const id: string = p[0].id;
  const b: "boxes" = p._brand;
  return [id, b, p.length];
};

// negative control: a property on neither half is still missing.
export const l = (p: Mutable<Point>) => p.nope; // TS2339

// negative control: the element type is not widened by the map.
export const m = (p: Mutable<Point>) => {
  const s: string = p[0]; // TS2322
  return s;
};
