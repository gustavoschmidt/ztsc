// Spreading an `any`-typed source into an object literal poisons the WHOLE
// resulting object type to `any` (tsc: `{ ...anyVal, x }` has type `any`), so
// any member access on it — even a name that is not an explicit key — is
// unchecked. Previously ztsc dropped the any-spread and produced a closed
// object with only the explicit keys, which then raised spurious TS2339 on
// every access of a member that "came from" the spread source. This surfaced
// on custom hooks of the shape `return { ...state, refresh }` whenever `state`
// resolved to `any`.
declare const st: any;
declare const load: () => void;

function hook() {
  return { ...st, refresh: load };
}

const r = hook();
// All of these are OK: the object is `any`, so every access type-checks.
r.status;
r.data;
r.error;
r.refresh;
r.anythingAtAllGoesHere;

// A spread of a KNOWN object type is unaffected — it still yields a closed
// object, so a genuinely-absent member is still rejected (the any-poison is
// gated on the spread source actually being `any`).
declare const obj: { a: number };
const k = { ...obj, b: 1 };
k.a; // ok
k.b; // ok
k.missing; // TS2339
