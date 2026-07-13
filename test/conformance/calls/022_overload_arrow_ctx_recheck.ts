// The arrow argument is contextually typed once per overload candidate.
// Candidate 1 (tried first) types `x => {}` as `(x: string) => void` during
// its trial, then fails on the second argument. Candidate 2 wants
// `(x: number) => void` and is the real match; it must re-check the arrow
// under its own context. A node-only cache returns the stale
// `(x: string) => void`, which is not assignable to `(x: number) => void`
// (contravariant params), so ztsc wrongly reports TS2769. tsc picks
// candidate 2 with no error.
function h(cb: (x: string) => void, k: string): void;
function h(cb: (x: number) => void, k: number): void;
function h(cb: (x: any) => void, k: any): void {}
h((x) => {}, 5);
