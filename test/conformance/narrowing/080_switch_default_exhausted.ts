// tsc narrows the DISCRIMINANT type first in a `default:` clause and only
// then filters the constituents (`narrowTypeBySwitchOnDiscriminant`), so a
// `default:` whose `case` labels cover every discriminant value is `never` —
// even when a constituent's discriminant is itself a union of literals, and
// even when the switch is on a naked type parameter.
declare function assertNever(x: never, msg: string): never;

// (1) a constituent with a WIDE discriminant, fully covered.
type U = { type: "a" | "b"; ab: number } | { type: "c"; c: number };
export const f = (u: U): number => {
  switch (u.type) {
    case "a":
    case "b":
      return u.ab;
    case "c":
      return u.c;
    default:
      return assertNever(u, "boom");
  }
};

// (2) intersections: the narrowed constituent carries both spellings.
type Base = { x: number };
type Lin = Base & { type: "line" | "arrow"; pts: number[] };
type E = (Base & { type: "rect" }) | Lin | (Lin & { type: "arrow"; head: string });
export const g = (e: E): number => {
  switch (e.type) {
    case "rect":
      return 1;
    case "line":
      return 2;
    case "arrow":
      return 3;
    default: {
      const z: never = e;
      return z;
    }
  }
};

// (3) a naked type parameter whose constraint the cases cover.
export const h = <T extends "a" | "b" | "c">(t: T): number => {
  switch (t) {
    case "a":
    case "b":
      return 1;
    case "c":
      return 2;
    default:
      return assertNever(t, "boom");
  }
};

// (4) the plain single-literal union still works.
type V = { k: "x"; x: number } | { k: "y"; y: number };
export const i = (v: V): number => {
  switch (v.k) {
    case "x":
      return v.x;
    case "y":
      return v.y;
    default:
      return assertNever(v, "boom");
  }
};
