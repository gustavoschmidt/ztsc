// A property-PATH narrowing (`state.data`, `this.layer`) established by an
// early-return guard must survive a `for`/`for..of`/`while` loop body when
// neither the root symbol nor any of its properties is written inside the loop.
// tsc's `getTypeAtFlowLoopLabel` keeps a loop-invariant reference narrowed
// across the back edge; ztsc previously applied this only to bare identifiers,
// so a property path fell through to the union-over-antecedents path whose
// in-progress back edge re-widened the guarded-away `null`. Minimized from the
// dogfood project's conversation-kanban and split-tool loops. A write to the
// root — or to any of its properties — inside the loop correctly re-widens
// (negative controls). Lib-free: `for..of` over an `unknown[]` only.

interface Layer {
  fire(): void;
}

// POSITIVE (must NOT error) --------------------------------------------------
function p_forof(state: { data: { cols: number[] } | null }, arr: unknown[]): void {
  if (!state.data) return;
  for (const _ of arr) {
    const n: number[] = state.data.cols; // OK: narrowing survives the loop
    void n;
  }
}

class P_this {
  layer: Layer | null = null;
  run(arr: unknown[]): void {
    if (!this.layer) return;
    for (const _ of arr) {
      void 0;
    }
    this.layer.fire(); // OK: narrowing survives across the loop
  }
}

function p_while(state: { data: { cols: number[] } | null }): void {
  if (!state.data) return;
  let i = 0;
  while (i < 3) {
    const n: number[] = state.data.cols; // OK
    void n;
    i += 1;
  }
}

// NEGATIVE CONTROL (MUST error) ----------------------------------------------
// A write to the path inside the loop re-widens it.
function n_root_write(state: { data: { cols: number[] } | null }, arr: unknown[]): void {
  if (!state.data) return;
  for (const _ of arr) {
    state.data = null; // invalidates
    const n: number[] = state.data.cols; // error: state.data possibly null
    void n;
  }
}

class N_this_write {
  layer: Layer | null = null;
  run(arr: unknown[]): void {
    if (!this.layer) return;
    for (const _ of arr) {
      this.layer = null; // invalidates
      this.layer.fire(); // error: possibly null
    }
  }
}
