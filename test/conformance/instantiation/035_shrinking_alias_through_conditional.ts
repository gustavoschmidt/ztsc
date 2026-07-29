// A recursive alias reached through a resolved conditional's TRUE BRANCH has
// no enclosing reference for the alias machinery to re-expand from, so the
// recursion used to stall one hop in. `Array.prototype.flat` is the shape:
// its return type is `FlatArray<A, D>[]`, and `FlatArray` recurs through
// `Arr extends ReadonlyArray<infer InnerArr> ? FlatArray<InnerArr, …> : Arr`.
declare const arr: (string | { id: string }[] | { id: string })[];

// A stalled alias reference is not a union, so `typeof` narrowing over the
// element saw nothing to filter.
export const ids: string[] = arr
  .flat()
  .map((item) => (typeof item === "string" ? item : item.id));

// A BRANDED tuple is array-shaped through its intersection, so the recursive
// step is decidable even though the element type is a free type parameter.
type P = [number, number] & { _brand: "point" };
type Seg = [P, P] & { _brand: "segment" };
declare function polygonFrom<T extends P>(pts: T[]): T[];
export const poly = <T extends P>(segs: (readonly [T, T] & { _brand: "segment" })[]) =>
  polygonFrom(segs.flat());
declare const segs: Seg[];
export const poly2: P[] = polygonFrom(segs.flat());

// The same alias written out with explicit arguments still reduces (this
// always worked, and must keep working).
type A = typeof arr;
declare const d: FlatArray<A, 1>;
export const dd: string | { id: string } = d;
declare const e: FlatArray<A, 0>;
export const ee: string | { id: string }[] | { id: string } = e;

// A hand-written clone with the same recursion, reached the same way.
type MyFlat<Arr, D extends number> = {
  done: Arr;
  recur: Arr extends ReadonlyArray<infer I> ? MyFlat<I, [-1, 0, 1, 2][D]> : Arr;
}[D extends -1 ? "done" : "recur"];
declare function myFlat<Arr, D extends number = 1>(a: Arr, d?: D): MyFlat<Arr, D>;
export const m1: string | number = myFlat([["a"], [1]] as (string[] | number[])[]);
export const m2: string | number = myFlat<(string[] | number[])[], 1>([]);
