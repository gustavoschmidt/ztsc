// The distribution in 029 is all-or-nothing: a key set that is not entirely
// covered by the receiver keeps the whole access implicit-'any', so nothing
// downstream of it is reported either.
type Dir = "n" | "s" | "e";
declare const d: Dir;

// 'e' is missing, so the access stays 'any' and the assignment is silent.
declare const partial: { n: number; s: number };
const a: string = partial[d];

// A non-literal constituent in the key union does the same.
declare const wide: "n" | string;
declare const full: { n: number; s: number; e: number };
const b: string = full[wide];

// A union key wider than a tuple's length is not distributed either.
declare const tup: [string, number];
declare const i: 0 | 1 | 2;
const c: boolean = tup[i];
