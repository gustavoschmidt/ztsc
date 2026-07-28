// Inferring into a UNION parameter: constituents that match the argument's own
// constituents identically pair off first, and only the RESIDUAL argument is
// offered to the inference-bearing members.
type MyPick<T, K extends keyof T> = { [P in K]: T[P] };

declare class Comp<S> {
  setState<K extends keyof S>(
    state: ((prev: S) => MyPick<S, K> | S | null) | MyPick<S, K> | S | null,
  ): void;
}
type St = { a: number; b: number; c: string };
declare const comp: Comp<St>;

// the updater's return is `{ b: number } | null`; `null` pairs with the target's
// own `null` constituent, so `K` is inferred from `{ b: number }` alone
comp.setState((s) => (s.a ? { b: 1 } : null));
// still fine without the null
comp.setState((s) => ({ a: s.a + 1 }));
// a key that does not exist is still rejected
comp.setState((s) => (s.a ? { zz: 1 } : null)); // TS2345
// and a wrong value type for a real key is still rejected
comp.setState((s) => (s.a ? { b: "x" } : null)); // TS2345

// residual-of-one: nothing pairs, behaviour is unchanged
declare function g<T>(x: T[] | null): T;
declare const nums: number[] | null;
const n1 = g(nums);
const n2: number = n1;
void n2;

// every argument constituent pairs: no subtraction, the whole argument is used
declare function h<T>(x: T | string | null): T;
declare const sn: string | null;
const h1 = h(sn);
void h1;

// the naked-type-parameter fallback still subtracts by ASSIGNABILITY, not identity
declare function k<T>(x: T | undefined): T;
declare const su: string | undefined;
const k1 = k(su);
const k2: string = k1;
void k2;
