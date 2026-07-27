// `(A | B) & C` is a *union of intersections* — tsc's `getIntersectionType`
// distributes a union constituent into the cross product `A & C | B & C`, so no
// interned intersection ever holds a union member. Without the distribution the
// intersection had no property view (its union constituent answered nothing) and
// every member access, every assignment back to the union, and every element
// access through such a type was a false TS2339/TS2345 — the shape excalidraw's
// element model (`Ordered<T>` / `NonDeleted<T>` brands over a 10-member element
// union) uses everywhere.
type Base = Readonly<{ id: string; width: number }>;
type Rect = Base & Readonly<{ type: "rect" }>;
type Lin = Base & Readonly<{ type: "lin" }>;
type Elem = Rect | Lin;

// 1. member access straight through the intersection
type ND = Elem & { isDeleted: boolean };
declare const nd: ND;
export const id1: string = nd.id;
export const del: boolean = nd.isDeleted;

// 2. a property carried by only ONE union constituent is still absent
export const bad1 = nd.points;

// 3. assignability back to the bare union, bare and under an array
declare function takesElem(e: Elem): void;
takesElem(nd);
declare const arr: readonly ND[];
declare function takesArr(e: readonly Elem[]): void;
takesArr(arr);

// 4. the reverse direction does NOT hold — `Elem` lacks `isDeleted`
declare const el: Elem;
declare function takesND(e: ND): void;
takesND(el);

// 5. through a generic alias, instantiated with the whole union
type Ordered<T extends Elem> = T & { index: number };
declare const ord: Ordered<Elem>;
export const id2: string = ord.id;
export const idx: number = ord.index;

// 6. conditional types still see the distributed constituents
export const id3: string = (null as unknown as Exclude<ND, Lin>).id;

// 7. element access through an indexed access on the distributed form
export const w: number = (null as unknown as ND)["width"];

// 8. a distributed constituent keeps its own modifiers: `width` is readonly on
// `Base`, so writing through the intersection is still rejected.
nd.width = 3;
