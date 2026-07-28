// Negatives for `T & {}` truthiness narrowing: only the nullish half is
// removed, the constraint itself is not.
type Point = readonly [number, number];

export const a = <T extends Point | null>(p: T) => {
  if (p) {
    const s: string = p; // error: still the constraint, not a string
    return s;
  }
  return "";
};

// members outside the constraint are still not there
export const c = <T extends string | undefined>(s: T) => {
  if (s) {
    return s.missingMember; // error
  }
  return 0;
};

// the marker does not make an unrelated member appear
export const e = <T extends Point | null>(p: T) => {
  if (p) {
    return p.missingMember; // error
  }
  return 0;
};
