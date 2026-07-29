// The object side of a deferred `T[K]` target reduces by following the type
// parameter's constraint chain and STOPPING at the first non-parameter — tsc's
// `computeBaseConstraint` returns an object/array type unchanged. So
// `K extends readonly (keyof R)[]` gives `readonly (keyof R)[]`, and
// `K[number]` gives `keyof R`, not `readonly (keyof Record<string, any>)[]`
// and `string | number`.

export function pick<
  R extends Record<string, any>,
  K extends readonly (keyof R)[],
>(source: R, keys: K) {
  return keys.reduce((acc, key: K[number]) => {
    if (key in source) {
      acc[key] = source[key];
    }
    return acc;
  }, {} as Pick<R, K[number]>) as Pick<R, K[number]>;
}

// A deferred `keyof R` source meets a `K[number]` target by identity — the
// target is reduced before the source is widened to its apparent key union.
export function write<
  R extends Record<string, any>,
  K extends readonly (keyof R)[],
>(kr: keyof R) {
  const a: K[number] = kr;
  return a;
}

// Same with a concrete constraint on R.
export function writeConcrete<
  R extends { a: string; b: number },
  K extends readonly (keyof R)[],
>(kr: keyof R) {
  const b: K[number] = kr;
  return b;
}

// A mutable array constraint behaves the same.
export function writeMutable<
  R extends Record<string, any>,
  K extends (keyof R)[],
>(kr: keyof R) {
  const cc: K[number] = kr;
  return cc;
}

// A parameter CHAIN still reaches the shape at the end of it.
export function chain<T extends { version: number }, U extends T>() {
  const d: U["version"] = 1;
  return d;
}
