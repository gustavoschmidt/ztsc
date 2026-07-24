// An empty array literal `[]` under a UNION context with two or more array-like
// branches of differing element types must not fold every branch's element into
// a union element (`(E | E[])[]`), which is assignable to no single branch — a
// false TS2345. With no elements the literal is `never[]`, assignable to every
// array/tuple branch. Mirrors leaflet's `polyline([], …)` where the first
// parameter is `LatLngExpression[] | LatLngExpression[][]`.
interface LatLng {
  lat: number;
  lng: number;
}
type LatLngTuple = [number, number, number?];
type LatLngExpression = LatLng | LatLngTuple;

declare function polyline(latlngs: LatLngExpression[] | LatLngExpression[][]): void;

polyline([]); // empty literal -> never[], OK against either branch

declare function f(x: number[] | number[][]): void;
f([]);

// non-empty and single-branch controls still work
declare const a: LatLngExpression[];
polyline(a);
declare const b: LatLngExpression[][];
polyline(b);
polyline([[1, 2]]);
polyline([{ lat: 1, lng: 2 }]);

// single array context: element type preserved (not collapsed to never)
const single: (number | string)[] = [];
single.push(1);
single.push("x");
