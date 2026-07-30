// Negatives for the intersection-source / recursive-intersection-alias-target
// relation (see 074_intersection_to_recursive_alias.ts). Re-dispatching the
// target through the intersection rule must still MEET every constituent.
type Node<T> = T & {
  prev: Node<T> | null;
  next: Node<T> | null;
};

// A link field missing entirely: the object constituent goes unmet.
export const missingLink = <T>(curr: T): Node<T> => {
  const node: Node<T> = { ...curr, prev: null };
  return node;
};

// A link field of the wrong type.
export const wrongLink = <T>(curr: T): Node<T> => {
  const node: Node<T> = { ...curr, prev: null, next: 1 };
  return node;
};

// The `T` constituent goes unmet: nothing supplies it.
export const missingParam = <T>(): Node<T> => {
  const node: Node<T> = { prev: null, next: null };
  return node;
};

// A concrete instantiation whose payload half is wrong.
type Chain<T> = T & { prev: Chain<T> | null };
export const badPayload = (): Chain<{ id: string }> => {
  const node: Chain<{ id: string }> = { id: 1, prev: null };
  return node;
};

// A link typed as the bare payload, not as the recursive alias.
export const unlinkedPrev = (): Chain<{ id: string }> => {
  const node: Chain<{ id: string }> = { id: "a", prev: { id: "b" } };
  return node;
};
