// A type-parameter source whose constraint is itself a union relates to a
// union target as a whole (through its constraint), not member-by-member.
// The `<T extends AllGeoJSON>(f: T): T` residue: `T` flows into a generic call
// whose parameter is typed by the same union constraint.
type All = { a: number } | { b: string } | { c: boolean };

declare function truncate<U extends All>(g: U, opts?: { precision: number }): U;

export function myTrunc<T extends All>(feature: T): T {
  return truncate(feature, { precision: 7 }); // ok — T's constraint union relates to All
}

// Direct: a constrained type parameter is assignable to its own constraint.
export function toAll<T extends All>(x: T): All {
  return x; // ok
}
