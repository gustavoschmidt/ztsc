// A cast through a DEFERRED indexed access (`T[K]`). tsc rejects one only when
// `getBaseConstraintOfType` fully reduces the access — which needs the object
// constraint to answer for every key the index constraint admits, i.e. an index
// signature or mapped template. Everything else stays deferred and overlaps.
// The companion to indexed/022 (deferred `keyof T`) and conditional/030.
export {};

// `T[K]` reduced to `number` by a `Record<keyof T, number>` constraint.
function f<T extends Record<keyof T, number>, K extends keyof T>(n: number) {
  return n as T[K];
}

// the same object constraint, read the other way
function g<T extends Record<keyof T, number>, K extends keyof T>(v: T[K]) {
  return v as number;
}

// an object constraint with named properties does NOT reduce, so any cast
// through it overlaps
function h<T extends { a: number; b: number }, K extends keyof T>(n: number) {
  return n as T[K];
}
function i<T extends { a: number; b: number }, K extends keyof T>(s: string) {
  return s as T[K];
}

// an unconstrained parameter overlaps everything, as it does bare
function j<T, K extends keyof T>(s: string) {
  return s as T[K];
}

// the shape the app hits: an evolving `let` resolved to `number`, cast into the
// record's value type
declare function ease(from: number, to: number, p: number): number;
function step<T extends Record<keyof T, number>, K extends keyof T>(
  out: T,
  key: K,
  from: number,
  to: number,
  p: number,
) {
  let result;
  result = ease(from, to, p);
  out[key] = result as T[K];
}
