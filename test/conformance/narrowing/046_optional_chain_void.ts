// Optional-chain receiver narrowing drops `void` as well as null/undefined.
// A `.catch(() => {})` / `.then(…)` promise tail types a resolved value
// `T | void`, and tsc lets `x?.prop` reach through the `void` constituent to
// `T`'s members (the whole chain still yields `… | undefined`). Mirrors the
// dogfood project's `fetchProject(id).then((enriched) => enriched?.family?.id)`.
// Scoped to `?.` / `?.[]` / `?.()` links (a plain `.` access on a `void | T`
// value still reports, and `??` / `!` narrowing are unaffected). All member
// names resolve without lib.d.ts, so every access below is clean.

declare const a: void | { family: { id: string } };
const r1 = a?.family?.id; // ok: `?.` reaches through void
const r2 = a?.family; // ok

declare const b: void | { call: () => number };
const r3 = b?.call(); // ok: optional call through void

declare const c: void | { items: { first: string }[] };
const r4 = c?.items?.[0]?.first; // ok: optional index through void
