// A still-GENERIC mapped type (`Record<T, any>` with `T` abstract) has no
// NAMED members — its key set is unknown, so tsc's `getPropertyOfType` finds
// nothing in `resolveStructuredTypeMembers`. But a mapped type is still an
// object type there, so the tail of that function —
// `getPropertyOfObjectType(globalObjectType, name)` — still supplies the
// apparent `Object` members. Reading `hasOwnProperty` off one is therefore
// legal; ztsc answered TS2339 for every name.

export const isMemberOf = <T extends string>(
  collection: Set<T> | readonly T[] | Record<T, any> | Map<T, any>,
  value: string,
): value is T => {
  return collection instanceof Set || collection instanceof Map
    ? collection.has(value as T)
    : "includes" in collection
    ? collection.includes(value as T)
    : collection.hasOwnProperty(value);
};

// Directly, without the narrowing: the same members are there.
export function objectMembers<K extends string>(r: Record<K, number>) {
  return [
    r.hasOwnProperty("k"),
    r.propertyIsEnumerable("k"),
    r.toString(),
    r.valueOf(),
  ];
}

// A homomorphic map over a generic source behaves the same.
export function homomorphic<T extends { a: number }>(m: Readonly<T>) {
  return m.hasOwnProperty("a");
}

// `Omit` of a generic — the non-homomorphic route.
export function nonHomomorphic<T extends { a: number; b: string }>(
  m: Omit<Partial<T>, "b">,
) {
  return m.hasOwnProperty("a");
}
