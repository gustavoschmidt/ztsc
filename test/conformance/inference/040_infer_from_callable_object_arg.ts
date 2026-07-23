// Call-site type-argument inference must read a callable OBJECT argument's
// CALL signature when it is matched against a function-typed parameter — the
// sibling of 039's conditional-infer path, on the unify()/inferTypeArgs path.
// `mapArr(strs, Num)` must infer U=number from NumberConstructor's
// `(value?: any): number` call signature standing in for a bare function.
// Without it U=unknown and arithmetic (TS2362/2363) + assignability (TS2322)
// cascade downstream. Self-contained (no lib dependency).

interface NumberCtor {
  (value?: any): number;
  new (value?: any): number;
  readonly MAX: number;
}
declare const Num: NumberCtor;

declare function mapArr<T, U>(arr: T[], cb: (v: T, i: number) => U): U[];
declare const strs: string[];

const nums = mapArr(strs, Num); // U inferred as number
const n0: number = nums[0];
const diff = nums[0] - nums[1]; // arithmetic OK once U=number

// Overloaded callable object: tsc aligns signatures from the end, so the LAST
// call signature supplies U.
interface OvCall {
  (v: string): string;
  (v: number): boolean;
}
declare const Ov: OvCall;
const bs = mapArr([1, 2], Ov); // last sig (v: number): boolean -> U=boolean
const b0: boolean = bs[0];

// Negative control: a plain object with NO call signature is not a function —
// the `ncall == 0` guard binds nothing and the arg itself is rejected (TS2345),
// exactly as tsc reports. Confirms the callable-object path does not fabricate a
// signature for a non-callable object.
interface Plain {
  a: number;
}
declare const Pl: Plain;
const bad = mapArr(strs, Pl);
