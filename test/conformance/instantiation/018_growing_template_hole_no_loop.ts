// Negative control for the recursive template-hole reduction (sibling to 017
// and to 010's growing-bare-ref control). A conditional alias whose FALSE
// branch embeds a self-recursive reference INSIDE a template-literal hole
// while GROWING its type argument each hop — `` `a.${Grow<{ deeper: T }> &
// string}` `` — must be BOUNDED, never looped. The 017 fix drives an
// intersected template hole's member refs structurally; here that driving
// grows the argument without bound, so the reduction must hit the shared
// instantiation guards and STOP — exactly the guarantee that keeps the fix
// from diverging. The guard that fires is the chain-repetition cut
// (`max_chain_repeats`): the alias re-enters its own instantiation on every
// hop. tsc reports TS2589 (at the deep template node, line 16) plus the
// TS2322 at the annotation; the cut is silent, so ztsc reports only the
// TS2322 — the same deterministic under-report as 003 and 010, registered in
// `test/conformance/DEFERRED`. If the guard regressed to eager unbounded
// expansion, this input would not terminate.
type Grow<T> = [T] extends [{ stop: true }] ? "" : `a.${Grow<{ deeper: T }> & string}`;
declare const s: string;
const p: Grow<{ x: 1 }> = s;
export {};
