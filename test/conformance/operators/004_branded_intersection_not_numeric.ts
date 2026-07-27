// The other side of 003: looking into an intersection must not make every
// intersection numeric, and the widened `number` result must not be
// assignable back to the brand.
type Radian = number & { _brand: "radian" };

declare const r: Radian;
declare const sb: string & { _brand: "name" };
declare const ob: { a: number } & { b: string };

// the arithmetic result widens to `number`, which is NOT a Radian
const bad1: Radian = r * 2;
const bad2: Radian = r + 1;

// no numeric constituent — still TS2362 / TS2363 / TS2365
const bad3 = sb * 2;
const bad4 = 2 * ob;
const bad5 = ob + 1;
const bad6 = ob - 1;

// mixed relational: one side number-like, the other not
const bad7 = r < sb;

// a type parameter whose constraint has no numeric constituent
function nope<T extends string & { _brand: "name" }>(x: T) {
  return x * 2;
}

// compound assignment stays as strict as plain assignment: `number` is not
// assignable to `Radian`.
let mv: Radian = r;
mv += 1;

export { bad1, bad2, bad3, bad4, bad5, bad6, bad7, nope, mv };
