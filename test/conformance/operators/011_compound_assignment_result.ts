// A compound assignment stores the OPERATION's result, so the result type
// is checked back against the target exactly as `=` would check it
// (tsc's `checkAssignmentOperator`). The target reads at the BASE of its
// literal type there, which is what keeps the accepted half accepted.

// --- accepted: the target widens to its literal base ------------------
let dir: -1 | 1 = 1;
dir *= -1;
let mode: "a" | "b" = "a";
mode += "b";
let n = 0;
n += 1;
n -= 1;
n *= 2;
n <<= 1;
n |= 4;
let s = "";
s += "x";
s += 1;
let b = 1n;
b += 1n;
b *= 2n;

enum NumE {
  A,
  B,
}
let e: NumE = NumE.A;
e += 1;
e |= NumE.B;
let em: NumE.A = NumE.A;
em += 1;

declare let anyv: any;
anyv += 1;
n += anyv;

// --- rejected: the result is not assignable back ----------------------
type Radian = number & { _brand: "radian" };
declare const r: Radian;
let mv: Radian = r;
mv += 1;
mv *= 2;
mv -= 1;

enum StrE {
  A = "a",
}
let se: StrE = StrE.A;
se += "x";

function f<T extends number>(x: T) {
  let t = x;
  t += 1;
  return t;
}

export { dir, mode, n, s, b, e, em, mv, se, f };
