// A recursive alias group has exactly ONE spelling.
//
// `Item` is an intersection alias on a cycle: `Item` -> `Base` -> `Bound` ->
// `Item`. References taken while `Item`'s body is still materializing get a
// lazy `.ref`; references taken afterwards used to get a second, separately
// interned structural materialization of the same type. Both denote `Item`,
// but as distinct `TypeId`s they cannot dedupe inside a union or intersection,
// and which references land on which side of the cut depends on the order the
// checker reaches the declarations — i.e. on the checker count. That made the
// element-union family of a real project report different diagnostics at
// --checkers=1 and --checkers=8.
//
// `aliasInstance` now answers with the ref in both cases. Every assignment
// below crosses the two positions — an annotation written inside the recursive
// group (`Bound["owner"]`, `Base["bound"]`) and one written outside it — so
// they only typecheck when the two positions are the same type. tsc: silent.
type Bound = Readonly<{ owner: Item | null; kind: "arrow" | "text" }>;
type Base = { id: string; bound: readonly Bound[] | null };
type Item = Base & { tag: "item" };
type Other = Base & { tag: "other" };

// Written INSIDE the group: holds whatever spelling the cycle cut produced.
type Owner = Bound["owner"];
type BoundList = Base["bound"];

declare const inner: Owner;
declare const outer: Item;
declare const list: BoundList;

declare function takeItem(i: Item): void;
declare function takeOwner(o: Owner): void;
declare function takeBounds(b: readonly Bound[]): void;

// Both directions of the pair.
takeItem(inner as Item);
takeOwner(outer);
if (list) {
  takeBounds(list);
}

// A union that would carry the same type twice if the spellings diverged.
const both: Item | Owner = outer;
takeOwner(both);
const lit: Item | Owner = { id: "x", bound: null, tag: "item" };
takeItem(lit as Item);

// Discriminated union over the group still narrows.
declare const either: Item | Other;
if (either.tag === "item") {
  takeItem(either);
}

// Inference through a generic must land on one type, not on a union of the
// two spellings.
declare function first<T>(a: readonly T[]): T;
takeItem(first([outer, inner as Item]));
