// A reference path is tracked up to `max_ref_depth` links; anything longer is
// untracked, which is sound as a TYPE but reports a false positive at the use.
// Five links is what a `this.state.a.b.c` guard needs.
type LE = { elbowed: boolean; pds: { seg: { index: number | null } } };
declare function f(i: number): void;

class C {
  state: { sel: LE | null } = { sel: null };
  m() {
    if (
      this.state.sel &&
      this.state.sel.elbowed &&
      this.state.sel.pds.seg.index
    ) {
      const index = this.state.sel.pds.seg.index;
      f(index);
    }
  }
}
export const c = new C();

// The same depth off a plain root, and through a constant element access.
declare const o: { a: { b: { c: { d: number | null } } } };
export const g = () => {
  if (o.a.b.c.d) {
    f(o.a.b.c.d);
  }
};
declare const arr: { a: { b: { c: number | null } } }[];
export const h = () => {
  if (arr[0].a.b.c) {
    f(arr[0].a.b.c);
  }
};
