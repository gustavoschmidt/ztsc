// Arithmetic on a *branded* primitive. tsc classifies an operand by
// assignability to the primitive (`isTypeAssignableToKind`), so an
// intersection qualifies when ANY constituent does: `number & { _brand }` is
// a number for `* / - % ** & | ^ << >>`, for `+`, and for the relational
// operators — and the RESULT widens to the base primitive (`number`), never
// to the brand. A union still requires EVERY constituent to qualify, and a
// type parameter defers to its constraint.
type Radian = number & { _brand: "radian" };
type Brand<T, B extends string> = T & { __brand: B };
type Px = Brand<number, "px">;
type Name = string & { _brand: "name" };
type Big = bigint & { _brand: "big" };

declare const r: Radian;
declare const r2: Radian;
declare const p: Px;
declare const nm: Name;
declare const bg: Big;

// binary arithmetic — operand accepted, result is `number`
const a1: number = r * 2;
const a2: number = 2 * r;
const a3: number = r + 1;
const a4: number = r - r2;
const a5: number = r % 2;
const a6: number = r ** 2;
const a7: number = r & 1;
const a8: number = r << 2;
const a9: number = p / 2;

// relational
const c1: boolean = r < r2;
const c2: boolean = r >= p;

// unary and ++/--
const u1: number = -r;
let mv: Radian = r;
mv++;
--mv;

// branded string concatenation, branded bigint arithmetic
const s1: string = nm + "!";
const s2: string = "deg " + r;
const b1: bigint = bg * 2n;

// a type parameter constrained to a branded number
function scale<T extends Radian>(x: T): number {
  return x * 2;
}

// a union qualifies when every constituent does
function both(x: Radian | number): number {
  return x * 2;
}

export { a1, a2, a3, a4, a5, a6, a7, a8, a9, c1, c2, u1, s1, s2, b1, scale, both };
