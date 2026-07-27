// Negatives around the condition's reference candidate: only the assignment's
// TARGET is narrowed (not the source), only the comma's RIGHT operand, and a
// compound arithmetic assignment is not a reference candidate for the value.
declare function next(): { index: number } | null;

// The narrowing applies to the target, not to some other variable.
let a: { index: number } | null = null;
let b: { index: number } | null = null;
if ((a = next()) !== null) {
  const x: number = b.index;
}

// The comma's LEFT operand is not the candidate.
let c: { index: number } | null = null;
let d: { index: number } | null = null;
if (((c = next()), (d = next())) !== null) {
  const y: number = c.index;
}

// The false branch of a truthy assignment condition keeps the falsy part.
let e: { index: number } | null = null;
if ((e = next())) {
  // narrowed
} else {
  const z: number = e.index;
}

// A later plain write re-widens.
let f: { index: number } | null = null;
if ((f = next()) !== null) {
  f = next();
  const w: number = f.index;
}
