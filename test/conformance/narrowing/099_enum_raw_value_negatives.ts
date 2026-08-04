// The raw-value enum guard must not over-narrow.
enum E {
  A = "a",
  B = "b",
}

declare const e: E;

// A value no member carries narrows nothing on either branch.
function unknownValue(): E {
  if (e === "zzz") {
    return e;
  }
  return e;
}

// Wrong branch: `e === "a"` leaves `E.A`, which has no `B`-ness.
function wrongBranch(): E.B {
  if (e === "a") {
    return e;
  }
  throw new Error();
}

// A union that mixes the enum with a plain string keeps the literal
// comparand for the string constituent.
declare const mixed: E | string;
function withString(): E.A {
  if (mixed === "a") {
    return mixed;
  }
  throw new Error();
}

// A non-discriminant property is not narrowed by an equality on it.
type P = { id: string; a: number } | { id: string; b: number };
declare const p: P;
function notDiscriminant(): number {
  if (p.id === "x") {
    return p.a;
  }
  return 0;
}

export { unknownValue, wrongBranch, withString, notDiscriminant };
