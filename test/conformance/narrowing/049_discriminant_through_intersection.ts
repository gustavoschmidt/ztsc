// Discriminant narrowing has to see through `(A | B | C) & Brand`. Distributing
// the intersection into `A & Brand | B & Brand | C & Brand` puts the union
// outermost, which is the form the flow analyser already narrows: `===` on the
// discriminant, `switch`, and exhaustiveness (the `never` default) all work
// unchanged. Undistributed, the whole thing was one opaque intersection: no
// discriminant, no narrowing, and TS2678/TS2367 on every comparison.
type Rect = { type: "rect"; width: number };
type Lin = { type: "lin"; points: number };
type Ell = { type: "ell"; rx: number };
type Elem = Rect | Lin | Ell;
type ND = Elem & { isDeleted: boolean };

declare const nd: ND;

// 1. `===` on the discriminant narrows to the matching constituent
if (nd.type === "rect") {
  const w: number = nd.width;
}

// 2. the negative branch drops that constituent
if (nd.type !== "rect") {
  const bad = nd.width;
}

// 3. `switch` over the discriminant, with exhaustiveness
declare function sink(n: never): void;
export function area(e: ND): number {
  switch (e.type) {
    case "rect":
      return e.width;
    case "lin":
      return e.points;
    case "ell":
      return e.rx;
    default:
      sink(e); // exhaustive: `e` is `never` here
      return 0;
  }
}

// 4. a case label outside the discriminant's domain is still TS2678
export function bogus(e: ND): number {
  switch (e.type) {
    case "polygon":
      return 1;
    default:
      return 0;
  }
}

// 5. the brand survives narrowing
if (nd.type === "lin") {
  const both: boolean = nd.isDeleted;
  const pts: number = nd.points;
}
