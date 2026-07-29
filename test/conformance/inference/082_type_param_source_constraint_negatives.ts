// Negatives for the apparent-source rule (see 081): the constraint must NOT
// displace the type variable when the target is an inference position, and a
// constraint that matches nothing structurally must leave the naked member to
// answer with the original `T`.

interface El {
  id: string;
  x: number;
}

declare const castArray: <U>(value: U | U[]) => U[];
declare const idf: <U>(value: U) => U;
declare const opt: <U>(value: U | undefined) => U;

// A non-union constraint contributes nothing against `U[]`, so the naked
// member answers: U = T. (If it were `El`, `T[]` would reject the result.)
export const objConstraint = <T extends El>(e: T) => {
  const a = castArray(e);
  const same: T[] = a;
  return same;
};

// A primitive-union constraint is iterable but not array-like: `string` must
// not infer `U = string` through the `U[]` member. U = T.
export const primConstraint = <T extends string | number>(e: T) => {
  const a = castArray(e);
  const same: T[] = a;
  const notStr: string[] = a; // TS2322: T[] is not string[]
  return [same, notStr];
};

// A naked inference target keeps the original source, constraint or not.
export const nakedTarget = <T extends El | El[]>(e: T) => {
  const a = idf(e);
  const same: T = a;
  return same;
};

// `U | undefined` is a union whose only inference-bearing member is naked:
// the original source still wins.
export const optTarget = <T extends El | El[]>(e: T) => {
  const a = opt(e);
  const same: T = a;
  return same;
};
