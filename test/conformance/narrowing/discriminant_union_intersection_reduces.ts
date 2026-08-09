// tsc's `getReducedType`: an intersection whose merged property comes out
// `never` IS `never`, and the property merge distributes — `"c" & ("a" | "b")`
// is `("c" & "a") | ("c" & "b")` = `never`. ztsc's discriminant reduction only
// compared two UNIT types, so a discriminant narrowed to a union of units left
// the contradicting product standing.
//
// `SavedFeedItem & { type: "feed" | "list" }` is the shape: the union member
// whose `view` is `undefined` survived the intersection, so `view` kept its
// `undefined` constituent through every later discriminant narrowing and each
// use of it was a spurious TS18048.

type U =
  | { type: "a"; view: { x: number } }
  | { type: "b"; view: { y: number } }
  | { type: "c"; view: undefined };

declare const v: U & { type: "a" | "b" };
export const n1: number = v.type === "a" ? v.view.x : v.view.y;

// A single unit on the narrowing side already worked; it must keep working.
declare const w: U & { type: "a" };
export const n2: number = w.view.x;

// Overlapping sets do NOT reduce: the `"b"` product survives and `view` is
// still the union of both branches.
declare const p: U & { type: "b" | "c" };
export const n3: number = p.type === "b" ? p.view.y : 0;

// A non-unit member on either side is not provably disjoint and is kept.
declare const q: U & { type: string };
export const n4: string = q.type;

// The plain union is untouched.
declare const r: U;
export const n5: number = r.type === "a" ? r.view.x : 0;
