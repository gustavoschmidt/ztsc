// A source that is a type VARIABLE contributes to inference through its
// constraint whenever the target position is not itself an inference
// variable (tsc's `inferFromTypes` apparent-source rule).
//
// `castArray(element)` with `element: T` (T extends El | El[]) against
// `(value: U | U[]) => U[]` must infer `U = El`, not `U = T`: the union
// target hands its naked member the original `T`, but the `U[]` member
// sees the constraint and pairs `El[]` with `U[]`.

interface El {
  id: string;
  x: number;
}

declare const castArray: <U>(value: U | U[]) => U[];
declare const arr2: <U>(value: U[] | U[][]) => U;
declare const takeEls: (v: El[]) => void;

// U = El, so the result is El[] — an El[] parameter accepts it, and a T[]
// annotation does not (El is only assignable to T's constraint).
export const routed = <T extends El | El[]>(element: T) => {
  const elements = castArray(element);
  takeEls(elements);
  const notT: T[] = elements; // TS2322: El[] is not T[]
  return notT;
};

// Both union members are wrappers: `El[] | El[][]` pairs positionally, so
// U = El rather than T.
export const nested = <T extends El[] | El[][]>(element: T) => {
  const one = arr2(element);
  const notT: T = one; // TS2322: El is not T
  return one;
};

// The routed element really is `El`, not the opaque `T`: reading an `El`
// property off it is accepted.
export const reads = <T extends El | El[]>(element: T) => {
  const elements = castArray(element);
  return elements[0].id;
};
