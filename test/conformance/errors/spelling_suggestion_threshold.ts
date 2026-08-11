// tsc's `getSpellingSuggestion` is not a plain edit distance: a SUBSTITUTION
// costs twice an insert or a delete (0.1 when the two characters differ only
// in case), and the bound to beat is `floor(name.length * 0.4) + 1`. So a
// name reachable by adding or dropping characters gets a "Did you mean",
// and one that needs letters exchanged does not.
//
// With symmetric unit costs every case in the first group also fitted, and
// the plain TS2339/TS2304 tsc emits became a bogus TS2551/TS2552 pointing at
// an unrelated member.

declare class Base {
  move(): void;
  all: string[];
  restore(): void;
  data: Map<string, string>;
  isLoaded: boolean;
  fetchPage(): void;
}

declare const b: Base;

// Substitutions — out of range, so plain TS2339 with no suggestion.
b.sort;
b.rootStore;
b.add;
b.save;

// Deletions / insertions — in range, so TS2551 with the suggestion.
b.remove;
b.isLoade;
b.fetchPages;

// A case-only difference is nearly free.
b.ISLOADED;

// A short name still reaches a candidate one insertion away.
b.dat;

// The same rule drives the identifier arm (TS2304 vs TS2552).
const collections = 1;
collection;
const total = 1;
totol;
const nameLength = 1;
namLength;
const shortName = 1;
tallName;
