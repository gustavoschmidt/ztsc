// tsc's `getPropertyOfType` ends with `getPropertyOfObjectType(globalObjectType,
// name)`: every object type carries the apparent members of the global `Object`
// interface, and the assignability relation looks the SOURCE's properties up
// through exactly that function (`getUnmatchedProperty` /
// `propertiesRelatedTo`). So `object`, `{}`, an interface and a class instance
// are all assignable to `Object` and to `{ toString(): string }`, while a target
// that demands an INCOMPATIBLE `toString`/`valueOf`/`hasOwnProperty` still fails
// — including when it declares it optional, which the augment makes a real
// comparison rather than a vacuously satisfied weak type.
declare const o: object;
declare const e: {};
declare const num: number;
declare const str: string;
declare const fn: () => void;
declare const arr: number[];
interface Named {
  foo(): void;
}
declare const nm: Named;
class Cls {
  x = 1;
}
declare const ci: Cls;

// A. the global `Object` as target.
export const a1: Object = o;
export const a2: Object = e;
export const a3: Object = num;
export const a4: Object = str;
export const a5: Object = fn;
export const a6: Object = arr;
export const a7: Object = nm;
export const a8: Object = ci;
export const a9: Object = null as unknown as null; // not an object value

// B. structural pieces of `Object` as target.
export const b1: { toString(): string } = o;
export const b2: { toString(): string } = e;
export const b3: { toString(): string } = nm;
export const b4: { toString(): string } = ci;
export const b5: { hasOwnProperty(v: PropertyKey): boolean } = o;
export const b6: { constructor: Function } = o;
export const b7: { toString(): number } = e; // string is not number
export const b8: { valueOf(): number } = e; // Object is not number

// C. an OPTIONAL target member is compared too, not skipped.
export const c1: { toString?: () => string } = e;
export const c2: { toString?: () => number } = e;
export const c3: { valueOf?: () => number } = e;
export const c4: { hasOwnProperty?: number } = e;

// D. the augment supplies only the apparent members: a target's own required
// property is still missing (one name, not three).
interface WithToString {
  toString(): string;
  own: number;
}
export const d1: WithToString = e;
export const d2: WithToString = o;

// E. `Object` as SOURCE.
declare const ob: Object;
export const e1: {} = ob;
export const e2: object = ob;
export const e3: { toString(): string } = ob;

// F. the excess-property check bails wholesale on an `Object` target
// (`isTypeSubsetOf(globalObjectType, target)`), the way it does on `{}` — but
// not on a structural target that merely happens to be satisfied by it.
export const f1: Object = { a: 1 };
export const f2: Object | number = { a: 1 };
export const f3: { toString(): string } = { a: 1 };
export const f4: {} = { a: 1 };
