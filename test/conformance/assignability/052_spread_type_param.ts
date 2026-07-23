// Spreading a bare type parameter keeps `T` as a spread member, so an
// object literal that spreads `T` (with or without added properties) is
// assignable back to `T` — matching tsc's generic spread type. An object
// literal that does NOT spread `T` is not assignable to `T`.
function f<T>(data: T): void {
  const a: T = { ...data };
  const b: T = { ...data, extra: 1 };
  const c: T = { extra: 1 }; // TS2322 — no spread of T
}

// Returning a spread-of-T augmentation as T (the transform-helper shape).
type A = { projects: { name: string }[] };
type B = { name: string };
function g<U = A | B>(data: U): U {
  if ((data as A).projects) {
    return { ...data, projects: (data as A).projects };
  }
  return { ...data, slug: (data as B).name };
}
