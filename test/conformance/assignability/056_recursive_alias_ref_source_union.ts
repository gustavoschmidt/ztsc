// A lazy alias self-reference captured while a recursive union alias is still
// in progress has kind `.ref`, not `.union_type`. When it later surfaces as a
// value — here the element type of a narrowed generic member's `G[]` field —
// relating it to the same union target must first RESOLVE the ref so the source
// union distributes. Without that, the ref-wrapped union source is wrongly
// required to fit a SINGLE target-union member and rejected (a false TS2345).
// Mirrors geojson's `Geometry` / `GeometryCollection<G extends Geometry =
// Geometry>` walked recursively.
interface GeometryCollection<G extends Geometry = Geometry> {
  type: "GeometryCollection";
  geometries: G[];
}
interface Point {
  type: "Point";
  coordinates: number[];
}
interface LineString {
  type: "LineString";
  coordinates: number[][];
}
type Geometry = Point | LineString | GeometryCollection;

declare function walk(g: Geometry): void;

// The element of a narrowed `GeometryCollection`'s `geometries` is the recursive
// alias `Geometry` (as a lazy ref); passing it back to `walk(g: Geometry)` is OK.
function narrowSwitch(geometry: Geometry): void {
  switch (geometry.type) {
    case "GeometryCollection":
      for (const g of geometry.geometries) walk(g);
      return;
  }
}

// Same via an `if` narrow.
function narrowIf(geometry: Geometry): void {
  if (geometry.type === "GeometryCollection") {
    for (const g of geometry.geometries) walk(g);
  }
}

// Directly annotated (materialized union arg) already worked — kept as control.
declare const gcDirect: GeometryCollection<Geometry>;
for (const g of gcDirect.geometries) walk(g);
