// Member-path discriminant narrowing: a discriminant test on a depth-1
// property path (`feature.geometry.type === "Point"`) narrows the union stored
// at that path (`feature.geometry`), so a subsequent access through the same
// path reads the narrowed member's own properties. tsc narrows any tracked
// reference by its discriminant, not just a root symbol; ztsc's RefKey tracks
// depth-1 member paths, so the same discriminant filter applies to them.
// Mirrors the dogfood-project geojson `Feature<Geometry>` shape (a
// discriminated union on a string-literal `type`, read through `f.geometry`).
// Negative controls (no narrowing, else-branch complement, non-literal
// comparand, wrong-member branch) must still error TS2339.
// Renamed minimized repros of dogfood-project patterns.
interface Point {
  type: "Point";
  coordinates: [number, number];
  pt: number;
}
interface LineString {
  type: "LineString";
  coordinates: [number, number][];
  ls: number;
}
interface Polygon {
  type: "Polygon";
  coordinates: [number, number][][];
  pg: number;
}
type Geometry = Point | LineString | Polygon;
interface Feature<G extends Geometry = Geometry> {
  type: "Feature";
  geometry: G;
}

// POSITIVE (must NOT error) --------------------------------------------------
// Member-path discriminant: `f.geometry` narrowed to Point.
function a(f: Feature) {
  if (f.geometry.type === "Point") {
    return f.geometry.pt; // OK: Point-only property
  }
  return 0;
}

// `!==` early return then use of the narrowed member.
function b(f: Feature) {
  if (f.geometry.type !== "Point") return 0;
  return f.geometry.pt; // OK: narrowed to Point
}

// switch on the member-path discriminant.
function c(f: Feature) {
  switch (f.geometry.type) {
    case "Polygon":
      return f.geometry.pg; // OK: narrowed to Polygon
    default:
      return 0;
  }
}

// Root-symbol discriminant still narrows two independent references (&&).
function d(g: Geometry, h: Geometry) {
  if (g.type === "Point" && h.type === "Point") return g.pt - h.pt; // OK
  return 0;
}

// NEGATIVE CONTROLS (MUST error TS2339) --------------------------------------
// No narrowing at all.
function n1(f: Feature) {
  return f.geometry.pt; // error: pt not on the whole union
}

// Else-branch complement (LineString | Polygon), read Point-only property.
function n2(f: Feature) {
  if (f.geometry.type === "Point") return 0;
  return f.geometry.pt; // error: pt not on LineString | Polygon
}

// Discriminant compared to a non-literal variable does not narrow to one member.
function n3(f: Feature, t: "Point" | "Polygon") {
  if (f.geometry.type === t) return f.geometry.pt; // error: pt not on Point | Polygon
  return 0;
}

// Narrowed to Polygon, read a Point-only property.
function n4(f: Feature) {
  if (f.geometry.type === "Polygon") return f.geometry.pt; // error: pt not on Polygon
  return 0;
}
