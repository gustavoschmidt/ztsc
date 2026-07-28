// Negatives: the narrowing is by the ASSIGNED position's type, so a position
// that can still be nullish stays nullish, and a target the assignment does not
// name keeps whatever it had.
declare const attr: string | null;
declare const pair: [string | null, number];

export const a = () => {
  let p: string | null = attr;
  p = p || "x";
  [p] = pair;
  return p.length; // error: back to string | null
};

// an optional tuple position keeps `undefined`
export const b = () => {
  let x: string | undefined = "a";
  let y: string | undefined = "b";
  [x, y] = ["one"] as [string, string?];
  return x.length + y.length; // error: 'y' possibly undefined
};

// an untouched target keeps its own narrowing
export const c = () => {
  let p: string | null = attr;
  let q: string | null = attr;
  p = p || "x";
  [, q] = ["a", "b"];
  return p.length + q.length;
};

// an object position that is optional keeps `undefined`
export const d = () => {
  let v: string | undefined = "a";
  ({ k: v } = {} as { k?: string });
  return v.length; // error: possibly undefined
};
