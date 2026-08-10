// An optional chain short-circuits as a whole, so its REST — the links after
// the `?.`, *including a call's argument list* — is reached only when every
// receiver was non-nullish. tsc binds that rest under the non-short-circuited
// branch (`bindOptionalChainFlow` / `bindOptionalChainRest`), which is what
// lets a later mention of the receiver inside the chain be already narrowed.
interface Inner {
  link: string;
  at(n: number): string;
}
interface Outer {
  inner?: Inner;
  recId: number;
  pick(n: number): string;
}
declare const o: Outer | undefined;

// The argument list hangs off a call node two links above the `?.`.
const a: string | undefined = o?.pick(o.recId);
const b: string | undefined = o?.inner?.at(o.recId);

// An element index is a rest too.
declare const map: { [k: string]: string } | undefined;
declare const key: { name: string; def: string } | undefined;
const c: string | undefined = key?.def && map?.[key.name];

// Non-optional links continue the same chain: `.at(...)`'s argument is still
// inside it.
const d: string | undefined = o?.inner?.at(o.recId).length ? o.inner.link : undefined;

// A parenthesis does not end the chain for the link that follows it — the
// `?.` still guards what comes after.
const e: string | undefined = (o?.inner)?.at(o.recId);

// A non-null assertion is a chain link as well.
const f: string | undefined = o?.inner!.at(o.recId);

// Condition position: the true branch sits at the end of the chain.
if (o?.inner?.at(o.recId)) {
  const g: Inner = o.inner;
}

export { a, b, c, d, e, f };
