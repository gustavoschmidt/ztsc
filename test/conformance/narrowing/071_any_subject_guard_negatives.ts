// Negatives for narrowing an `any` subject: once a guard has refined it, the
// refined type is enforced, and the branches the guard excludes keep `any`.
export const a = (x: any) => {
  if (typeof x === "string") {
    const n: number = x; // error: string is not number
    return n;
  }
  return 0;
};

export const b = (x: any) => {
  if (typeof x !== "string") {
    // the else branch of a typeof guard on `any` is still `any`
    const anything: number = x;
    return anything;
  }
  const bad: number = x; // error: string is not number
  return bad;
};

// (the harness lib for single-file cases has no `Array.isArray` predicate, so
// the array case uses an equivalent user-declared one)
declare function isAnyArray(v: unknown): v is any[];
export const c = (x: any) => {
  if (isAnyArray(x)) {
    const s: string = x; // error: any[] is not string
    return s;
  }
  return "";
};

type Box = { tag: "box"; n: number };
declare function isBox(v: unknown): v is Box;
export const d = (x: any) => {
  if (isBox(x)) {
    return x.missing; // error: no such property on Box
  }
  return 0;
};

// An assignment cannot narrow a variable declared `any`.
export const e = () => {
  let x: any = 1;
  x = "s";
  const n: number = x; // no error: still any
  return n;
};
