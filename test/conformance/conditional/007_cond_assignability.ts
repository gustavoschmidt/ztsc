// Assignability between deferred conditional types. While T is generic the
// conditional stays unresolved; two structurally identical conditionals are
// the same type (hash-consed), so the assignment is allowed.
type Cond<T> = T extends string ? number : boolean;

function same<T>(x: Cond<T>): Cond<T> {
  return x;
}

// Passing a deferred conditional where the same deferred conditional is
// expected is fine.
function relay<T>(x: Cond<T>): Cond<T> {
  return same<T>(x);
}

// A deferred conditional's value is assignable to the union of its branches.
function widen<T>(x: Cond<T>): number | boolean {
  return x;
}
