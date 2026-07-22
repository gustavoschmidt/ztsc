// tsc's canonical type-IDENTITY probe — `(<G>() => G extends X ? 1 : 2)
// extends (<G>() => G extends Y ? 1 : 2)` — is accepted iff X and Y are the
// SAME type. It is the engine of react-hook-form's `IsEqual<X,Y>` (and other
// libraries), which in turn gates `Path`/`PathValue` recursion via
// `AnyIsEqual`. Relating the two probe signatures by erasing their lone type
// param `G` to `any` collapses both conditional returns to `1 | 2`, making the
// probe report ANY two signatures assignable — so `IsEqual<X,Y>` was always
// `true`, even for distinct types. The relation must instead compare the two
// `extends` types (and branches) for identity.

type IsEqual<T1, T2> = T1 extends T2
  ? (<G>() => G extends T1 ? 1 : 2) extends <G>() => G extends T2 ? 1 : 2
    ? true
    : false
  : false;

type Ra = Record<string, any>;
type Obj = { attributes: Record<string, any> };

// Distinct types that are mutually ASSIGNABLE — the `any` index signature makes
// each assignable to the other — must still be `IsEqual = false`: identity, not
// assignability. (Was wrongly `true`: both signatures erased to
// `<G>() => (any extends _ ? 1 : 2)` = `<G>() => 1 | 2`, hence "equal".)
declare const e1: IsEqual<Obj, Ra>;
const c1: false = e1;

// Plainly distinct primitives are `false` too.
declare const e2: IsEqual<string, number>;
const c2: false = e2;

// Genuinely identical types stay `IsEqual = true` — the fix is not over-strict.
declare const e3: IsEqual<string, string>;
const c3: true = e3;

declare const e4: IsEqual<Ra, Ra>;
const c4: true = e4;

// Negative control: asserting the corrected `false` result is `true` MUST error
// (TS2322). Proves the identity relation genuinely decides the probe rather
// than accepting everything — without it this line would pass.
declare const e5: IsEqual<Obj, Ra>;
const bad: true = e5;
