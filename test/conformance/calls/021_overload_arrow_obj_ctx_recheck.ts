// Same contextual re-check staleness as 022, but with structurally-typed
// (object) arrow parameters, so the stale-signature rejection runs through
// the structural-assignability path. Candidate 1 (tried first, k: string)
// contextually types `p => {}` as `(p: { a: number }) => void` during its
// trial, then fails on the second argument. Candidate 2 wants
// `(p: { b: number }) => void`. A node-only cache (node_types and/or
// sig_cache) hands candidate 2 the stale `{ a: number }` signature, which is
// not assignable (contravariant params), so ztsc wrongly reports TS2769. tsc
// resolves to candidate 2 with no error.
function w(cb: (p: { a: number }) => void, k: string): void;
function w(cb: (p: { b: number }) => void, k: number): void;
function w(cb: (p: any) => void, k: any): void {}
w((p) => {}, 5);
