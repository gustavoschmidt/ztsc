// Loop-crossing narrowing: a reference narrowed *before* a loop keeps that
// narrowing across the loop body when the loop never assigns it. tsc's
// getTypeAtFlowLoopLabel only re-widens a reference at a loop back edge when the
// loop actually assigns it; a reference that is loop-invariant carries its
// pre-loop narrowing throughout. ztsc previously re-widened every reference at
// every loop back edge, so a `T | null` guarded by an early return re-acquired
// `| null` inside a following `for`/`while`.
//
// Mirrors the dogfood-project geojson shape: a `Shape<Poly | Mpoly> | null`
// value narrowed by `if (!x) return` and then read inside a `for..of` loop.
// Negative controls (a reference reassigned *inside* the loop) must still
// re-widen and error TS2345.
// Renamed minimized repros of dogfood-project patterns.
declare function need(x: string): void;

// POSITIVE (must NOT error) --------------------------------------------------

// param narrowed by an early return, read inside a for..of loop.
function a(w: string | null, xs: number[]) {
  if (!w) return;
  for (const _ of xs) need(w); // OK: w stays string across the loop
}

// const narrowed, read inside a while loop.
function b(v: string | null, n: number) {
  const w = v;
  if (!w) return;
  let i = 0;
  while (i < n) {
    need(w); // OK: w is loop-invariant, stays string
    i++;
  }
}

// let never reassigned anywhere, read inside a nested loop.
function c(v: string | null, xs: number[], ys: number[]) {
  let w: string | null = v;
  if (!w) return;
  for (const _ of xs) {
    for (const __ of ys) need(w); // OK
  }
}

// let reassigned only BEFORE the loop (not inside it) keeps its narrowing —
// the exact dogfood `let appBuffer = …; if (!appBuffer) return; for (…)` shape.
function d(xs: number[], seed: string | null) {
  let w: string | null;
  w = seed;
  if (!w) return;
  for (const _ of xs) need(w); // OK: w never assigned inside the loop
}

// NEGATIVE CONTROLS (MUST error TS2345) --------------------------------------

// let reassigned INSIDE a for..of loop re-widens at the back edge.
function n1(xs: number[]) {
  let w: string | null = "x";
  if (!w) return;
  for (const _ of xs) {
    need(w); // error: w is string | null again (reassigned below in the loop)
    w = Math.random() > 0.5 ? "y" : null;
  }
}

// let reassigned INSIDE a while loop re-widens at the back edge.
function n2(n: number) {
  let w: string | null = "x";
  if (!w) return;
  let i = 0;
  while (i < n) {
    need(w); // error: w is string | null again (reassigned below in the loop)
    w = Math.random() > 0.5 ? "y" : null;
    i++;
  }
}
