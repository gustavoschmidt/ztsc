// Overload probing contextually types a function argument against the
// candidate's parameter. The arrow's PARAMETERS take their types from that
// contextual signature, but a read of one inside the body is memoized under
// the (node, no-context) key — so a rejected candidate's answer would still be
// sitting in the memo when the next candidate re-checks the very same body.
//
// `fold` mirrors `Array.prototype.reduce`: the non-generic overload types
// `acc` as the element `E` (a string-literal union), so `acc.concat(e)`
// resolves `String.prototype.concat` and yields `string`. That overload is
// then rejected on the `string[]` seed — but its `acc: E` leaked, so the
// generic overload's re-check read `string` back out of the memo and inferred
// it as a candidate for `U` alongside the seed's `string[]`, resolving the
// call to `string | string[]`: an inference the arguments never carried.

type E = "jpg" | "png";
declare function fold(cb: (acc: E, cur: E) => E, seed: E): E;
declare function fold<U>(cb: (acc: U, cur: E) => U, seed: U): U;

// POSITIVE: the generic overload wins with U = string[].
const joined = fold((acc, e) => acc.concat(e), [] as string[]);
const joinedIsStrings: string[] = joined;

// POSITIVE: the same shape through a real `reduce`, whose third overload is
// the generic one (two non-generic candidates are probed before it).
declare const exts: E[];
const dotted = exts.reduce((acc, ext) => acc.concat(`.${ext}`), [] as string[]);
const dottedIsStrings: string[] = dotted;

// POSITIVE: the leaked read is not confined to the argument's own body — the
// same arrow reached through a nested call must come out clean too.
const nested = fold((acc, e) => [...acc, e].map((x) => `${x}`), [] as string[]);
const nestedIsStrings: string[] = nested;

// NEGATIVE: the accepted candidate's own body error is still reported —
// suppressing the trial's memo writes must not suppress its checking.
declare function pick<U>(cb: (x: U) => U, seed: U): U;
declare const s: string;
const bad = pick((x) => x.nope, s);

// NEGATIVE: the trial's contextual types are still the ones the body is
// checked against — a callback whose body does not fit the ONLY candidate is
// still reported there.
declare function only(cb: (acc: number, cur: E) => number, seed: number): number;
const worse = only((acc, e) => acc.concat(e), 0);
