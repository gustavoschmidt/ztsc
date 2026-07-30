// Reverse index-signature inference — tsc's `inferFromIndexTypes` — for the
// `Object.entries`/`Object.values` parameter `{ [s: string]: T } | ArrayLike<T>`.
//
// Two rules under test:
//  1. every applicable source member (each string-keyed property, plus the
//     source's own string index) is collected and their UNION inferred as ONE
//     candidate, so a source with differently-typed properties still fits;
//  2. a UNION source infers constituent by constituent, one candidate each, and
//     the covariant fold is `getCommonSupertype` — the leftmost candidate wins
//     when two have unrelated bases. That makes the argument stop fitting, and
//     the call falls to the `entries(o: {}): [string, any][]` overload.
//
// The assignment targets are deliberately impossible so the error text prints
// the inferred type.

declare const oneProp: { a: string };
const t1: 0 = Object.entries(oneProp); // [string, string][]

declare const twoProps: { a: string; b: number };
const t2: 0 = Object.entries(twoProps); // [string, string | number][]

declare const withIndex: { [k: string]: boolean };
const t3: 0 = Object.entries(withIndex); // [string, boolean][]

declare const sameUnion: { a: string } | { b: string };
const t4: 0 = Object.entries(sameUnion); // [string, string][]

declare const clashUnion: { a: string } | { a: number };
const t5: 0 = Object.entries(clashUnion); // falls to overload 2: [string, any][]

declare const disjointUnion: { a: string } | { b: number };
const t6: 0 = Object.entries(disjointUnion); // [string, any][]

declare const litUnion: { a: 1 } | { a: 2 };
const t7: 0 = Object.entries(litUnion); // literals over one base union: [string, 1 | 2][]

declare const widerUnion: { a: string } | { a: string; b: number };
const t8: 0 = Object.entries(widerUnion); // subtype fold: [string, string | number][]

declare const indexUnion: { [k: string]: string } | { [k: string]: number };
const t9: 0 = Object.entries(indexUnion); // [string, any][]

// An interface has no inferable index, so nothing is inferred either way.
interface Named {
  a: string;
}
declare const iface: Named;
const t10: 0 = Object.entries(iface); // [string, any][]

// Object.values takes the same parameter.
const t11: 0 = Object.values(twoProps);
const t12: 0 = Object.values(sameUnion);

export { t1, t2, t3, t4, t5, t6, t7, t8, t9, t10, t11, t12 };
