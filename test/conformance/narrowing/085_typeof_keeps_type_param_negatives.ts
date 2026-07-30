// Negatives for `typeof` narrowing of a type parameter (see
// 085_typeof_keeps_type_param.ts). Intersecting the filtered constraint back
// with `T` must not make the narrowing weaker: each branch still has to expose
// only the surviving constituent, and `T` itself is still not a concrete type.
declare function takeString(s: string): void;
declare function takeObj(o: { id: string }): void;

export const wrongBranch = <T extends { id: string } | string>(x: T) => {
  if (typeof x === "string") {
    // `T & string` has no `id`.
    takeObj(x);
    return x.id;
  }
  // `T & { id: string }` is not a string.
  takeString(x);
  return x.length;
};

// A `T` that was never narrowed is not assignable to either constituent.
export const unnarrowed = <T extends { id: string } | string>(x: T) => {
  takeString(x);
  takeObj(x);
};

// `T & string` is a `T`, but a plain `string` is not — the intersection must
// not make the relation symmetric.
export const notBackwards = <T extends { id: string } | string>(
  x: T,
  s: string,
): T => {
  if (typeof x === "string") {
    return s;
  }
  return x;
};

// A constraint constituent the guard rules out entirely: the branch is `never`,
// so reading a member of it is an error.
export const impossible = <T extends { id: string }>(x: T) => {
  if (typeof x === "string") {
    return x.length;
  }
  return x.id;
};
