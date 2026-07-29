// Reducing a `T[K]` target to its base constraint only ever admits what that
// constraint admits.

// `keyof Record<string, any>` does not include `symbol`.
export function n1<
  R extends Record<string, any>,
  K extends readonly (keyof R)[],
>(sy: symbol) {
  const a: K[number] = sy;
  return a;
}

// The element type is still checked.
export function n2<T extends { version: number }>(s: string) {
  const b: T["version"] = s;
  return b;
}

// A key of one parameter is not a key of another.
export function n3<
  R extends { a: string },
  S extends { b: number },
  K extends readonly (keyof R)[],
>(ks: keyof S) {
  const cc: K[number] = ks;
  return cc;
}

// A missing property gives the access no constraint at all, so nothing meets it.
export function n4<T extends { version: number }>(n: number) {
  const d: T["nope"] = n;
  return d;
}
