export {};

type Base = { version: number; id: string };

// `S -> T[K]` relates through the base-constraint instantiation of `T[K]`.
const f = <T extends Base>(el: T) => {
  const a: Pick<T, "version"> = { version: 1 };
  const b: { version: T["version"] } = { version: 1 };
  const c: T["version"] = 1;
  const d: T["id"] = "x";
  return [a, b, c, d];
};

// NEGATIVE: the constraint still has to accept the source.
const g = <T extends Base>(el: T) => {
  const a: T["version"] = "x";
  const b: T["id"] = 1;
  return [a, b];
};

// NEGATIVE: a generic index keeps the access opaque — nothing concrete is
// assignable to `T[K]`.
function h<T, K extends keyof T>(t: T, k: K) {
  const a: T[K] = 1;
  return a;
}

// A nested type parameter still resolves through the outer constraint.
function i<T extends Base, U extends T>(u: U) {
  const a: U["version"] = 1;
  return a;
}

export { f, g, h, i };
