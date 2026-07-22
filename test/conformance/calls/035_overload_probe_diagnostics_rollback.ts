// Overload resolution probes each candidate by contextually typing the
// arguments against that candidate's parameters and testing assignability. A
// context-sensitive argument (an arrow body) checked under a candidate that is
// ultimately REJECTED must not leak the diagnostics produced under its wrong
// contextual type.
//
// `fold` below mirrors `Array.prototype.reduce`: the non-generic overload
// `fold(cb: (Item, Item) => Item, init: Item)` is tried before the generic
// `fold<U>(cb: (U, Item) => U, init: U)`. The non-generic overload types
// `prev` as the element `Item` (an object), so the body's `prev + cur.w`
// reports TS2365 — then that overload is rejected on `init` (a number is not an
// `Item`) and the generic overload wins with `prev: number`. Pre-fix, the
// rejected candidate's TS2365 leaked; a clean POSITIVE here locks the roll-back.

type Item = { w: number };
declare function fold(cb: (prev: Item, cur: Item) => Item, init: Item): Item;
declare function fold<U>(cb: (prev: U, cur: Item) => U, init: U): U;
declare const zero: number;

// POSITIVE: the generic overload wins (prev: number); no operator error.
const total = fold((prev, cur) => prev + cur.w, zero);
const check: number = total;

// NEGATIVE CONTROL: a genuine error in the WINNING overload's callback body
// must still be reported (the roll-back only discards REJECTED-candidate
// diagnostics — the accepted candidate's are emitted exactly once).
declare function pick<U>(cb: (x: U) => U, init: U): U;
declare const s: string;
const bad = pick((x) => x.nope, s);
