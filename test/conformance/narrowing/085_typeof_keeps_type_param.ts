// `typeof` narrowing a TYPE PARAMETER must stay a subtype of that parameter.
//
// A type param narrows through its constraint — filtering `T` itself would
// collapse `typeof x === "object"` to `never`, since only concrete kinds are
// inspectable — but the answer has to be intersected back with `T`, exactly as
// tsc's `getNarrowedType` ends in `getIntersectionType([t, candidate])`. A bare
// filtered constraint is NOT assignable to `T`, and the value is read again at
// the merge of the two branches: `m.set(typeof e === "string" ? e : e.id, e)`
// reported `string | { id: string }` against parameter `T`. tsc: silent.
export const toMap = <T extends { id: string } | string>(
  items: readonly T[],
) => {
  const acc: Map<string, T> = new Map();
  for (const element of items) {
    acc.set(typeof element === "string" ? element : element.id, element);
  }
  return acc;
};

// Through `reduce`, with the union-typed parameter and the `instanceof`
// narrowing that guards it — the real shape.
export const arrayToMap = <T extends { id: string } | string>(
  items: readonly T[] | Map<string, T>,
) => {
  if (items instanceof Map) {
    return items;
  }
  return items.reduce((acc: Map<string, T>, element) => {
    acc.set(typeof element === "string" ? element : element.id, element);
    return acc;
  }, new Map());
};

// The narrowed branches must still be USABLE — the intersection has to expose
// the members of the surviving constraint constituent.
export const branches = <T extends { id: string } | string>(x: T): number => {
  if (typeof x === "string") {
    return x.length;
  }
  return x.id.length;
};

// And each branch is still a `T`, so it can be handed back where `T` is wanted.
declare function takeT<T>(x: T): void;
export const roundTrip = <T extends { id: string } | string>(x: T): T => {
  if (typeof x === "string") {
    takeT<T>(x);
    return x;
  }
  takeT<T>(x);
  return x;
};

// An unconstrained type parameter: the true branch is `T & string`, which is
// still a `T`, and the false branch is untouched.
export const bare = <T>(x: T): T => {
  if (typeof x === "string") {
    return x;
  }
  return x;
};

// `typeof x === "object"` must not collapse an unconstrained `T` to `never` —
// the reason narrowing goes through the constraint in the first place.
export const objectBranch = <T>(x: T): T => {
  if (typeof x === "object") {
    return x;
  }
  return x;
};

// A three-way constraint, narrowed twice, then handed on as `T`.
export const three = <T extends string | number | { id: string }>(x: T): T => {
  if (typeof x === "string") {
    return x;
  }
  if (typeof x === "number") {
    return x;
  }
  return x;
};

// The merge point of a plain if/else, not a ternary.
export const merged = <T extends { id: string } | string>(x: T): [string, T] => {
  let key: string;
  if (typeof x === "string") {
    key = x;
  } else {
    key = x.id;
  }
  return [key, x];
};
