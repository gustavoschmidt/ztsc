// A generic function is assignable to a concrete function-type parameter by
// instantiating its own type params (inferred from the target), even when the
// type param carries a constraint wider than the target — e.g. passing a
// generic identity `<T extends AllGeoJSON>(f: T) => T` to `Array.map`'s
// callback. Erasing the type param to its constraint would over-widen the
// covariant return and wrongly reject.
interface Feature<G = any, P = any> {
  type: "Feature";
  geometry: G;
  properties: P;
}
interface Point {
  type: "Point";
}
interface Poly {
  type: "Polygon";
}
type AllGeoJSON = Feature | Point | Poly | Feature[];

declare function truncate<T extends AllGeoJSON>(feature: T): T;
declare const feats: Feature<Point | Poly>[];

// generic constrained source -> Array.map callback: OK (T = Feature<…>)
const a = feats.map(truncate);

// unconstrained generic identity -> concrete callback: OK
declare function id<T>(x: T): T;
declare const nums: number[];
const b = nums.map(id);

// constraint satisfied by the target param (subtype): OK
interface Base {
  type: string;
}
declare function idBase<T extends Base>(x: T): T;
const c = feats.map(idBase);

// negative control: the inferred arg would violate the constraint — reject.
declare function needStr<T extends string>(x: T): T;
const bad: (v: number) => number = needStr;
