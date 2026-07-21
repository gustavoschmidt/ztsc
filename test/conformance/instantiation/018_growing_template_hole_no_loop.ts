// Negative control for the recursive template-hole reduction (sibling to 017
// and to 010's growing-bare-ref control). A conditional alias whose FALSE
// branch embeds a self-recursive reference INSIDE a template-literal hole
// while GROWING its type argument each hop — `` `a.${Grow<{ deeper: T }> &
// string}` `` — must be BOUNDED, never looped. The 017 fix drives an
// intersected template hole's member refs structurally; here that driving
// grows the argument without bound, so the reduction must hit the shared
// TS2589 instantiation-depth ceiling (`reduceTemplateChunks` /
// `resolveStructural`) and STOP — exactly the guarantee that keeps the fix from
// diverging. tsc likewise reports TS2589 (at the deep template node, line 15)
// plus the TS2322 at the annotation; ztsc reports TS2589 at the annotation
// site (line 17, its instantiation-trigger span) — a report-SITE difference on
// the same diagnostic, hand-verified. If the depth guard regressed to eager
// unbounded expansion, this input would not terminate.
type Grow<T> = [T] extends [{ stop: true }] ? "" : `a.${Grow<{ deeper: T }> & string}`;
declare const s: string;
const p: Grow<{ x: 1 }> = s;
export {};
