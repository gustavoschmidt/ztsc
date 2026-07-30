// An intersection SOURCE against a target that is a recursive intersection
// alias.
//
// A recursive alias whose body is an intersection has exactly ONE spelling —
// the lazy `.ref` (see instantiation/034) — so such a target reaches the
// relation as `.ref`, never as `.intersection`. The intersection-source arm
// used to hand the ref's expansion straight to the merged-members structural
// check, which requires an OBJECT target and therefore rejected outright.
// Spelling the same target out by hand always worked, so the two positions
// disagreed. tsc: silent on everything below.
type Node<T> = T & {
  prev: Node<T> | null;
  next: Node<T> | null;
};

// The real shape: a spread of a naked type parameter plus the link fields, so
// the source is `{ prev: null; next: null } & T`.
export const link = <T>(curr: T): Node<T> => {
  const node: Node<T> = { ...curr, prev: null, next: null };
  return node;
};

// Same relation with the target spelled out — the control that always held.
export const linkSpelled = <T>(curr: T): T & {
  prev: Node<T> | null;
  next: Node<T> | null;
} => {
  const node: T & { prev: Node<T> | null; next: Node<T> | null } = {
    ...curr,
    prev: null,
    next: null,
  };
  return node;
};

// Through an accumulating reduce, i.e. the target arrives via a contextual
// type rather than an annotation.
export const toList = <T>(array: readonly T[]): Node<T>[] =>
  array.reduce((acc, curr, index) => {
    const node: Node<T> = { ...curr, prev: null, next: null };
    if (index !== 0) {
      const prevNode = acc[index - 1];
      node.prev = prevNode;
      prevNode.next = node;
    }
    acc.push(node);
    return acc;
  }, [] as Node<T>[]);

// Single link field, and a concrete instantiation rather than a generic one.
type Chain<T> = T & { prev: Chain<T> | null };
export const one = <T>(curr: T): Chain<T> => {
  const node: Chain<T> = { ...curr, prev: null };
  return node;
};
export const concrete = (): Chain<{ id: string }> => {
  const node: Chain<{ id: string }> = { id: "a", prev: null };
  return node;
};

// A non-recursive intersection alias materializes to a real `.intersection`,
// so it took the other route; keep it as the second control.
type Flat<T> = T & { prev: number | null };
export const flat = <T>(curr: T): Flat<T> => {
  const node: Flat<T> = { ...curr, prev: null };
  return node;
};

// The recursive constituent is reachable transitively (`Ring` -> `Cell` ->
// `Ring`), which is the mutual-cycle form of the same cut.
type Cell<T> = { value: T; ring: Ring<T> | null };
type Ring<T> = T & { head: Cell<T> };
export const ring = <T>(curr: T, value: T): Ring<T> => {
  const node: Ring<T> = { ...curr, head: { value, ring: null } };
  return node;
};
