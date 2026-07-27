// The index expression of an optional chain link is evaluated only on the
// chain's non-nullish branch, so it sees the guards the chain has already
// made: `a?.b?.[…]` binds as `a && a.b && a.b[…]`. Inside the brackets both
// `a` and `a.b` are known non-nullish, so a repeat of the same chain there
// does not re-add the short-circuit `undefined`.
type Pt = { readonly x: number };
declare const u: { pts?: readonly Pt[] } | undefined;

// `u?.pts?.length` inside the brackets is `number`, not `number | undefined`,
// so the subtraction is legal.
export const last = u?.pts?.[u?.pts?.length - 1]?.x;

// The root-only form: `?.[` guards its own receiver.
declare const xs: number[] | undefined;
export const tail = xs?.[xs.length - 1];

// A `?.` earlier on the spine guards the root for a later, non-optional index.
declare const w: { ns: number[] } | undefined;
export const mid = w?.ns[w.ns.length - 1];

// NEGATIVE: a non-optional link asserts nothing about its own object, so a
// nullish intermediate still owes its diagnostics — both at the access itself
// and at the reads inside the brackets.
declare const v: { ns?: number[] } | undefined;
export const bad = v?.ns[v.ns.length - 1];

// NEGATIVE: the guards end with the chain. After it, nothing is narrowed.
export const after = u.pts;

// A guarded reference stays guarded for a nested chain link, but only for the
// references the chain actually asserted.
declare const g: { a?: { b?: number[] } } | undefined;
export const deep = g?.a?.b?.[g.a.b.length - 1];
