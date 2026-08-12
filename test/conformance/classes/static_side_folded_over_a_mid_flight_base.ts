// A class's STATIC side must never be memoized over a base whose own static
// fold is a frame further down the same stack.
//
// `open` demands the MIDDLE class's statics, which opens the window: `Mid` is
// folding `Base`'s statics when `Base`'s member walk reaches `Deep.f()` — three
// links DOWN the same heritage chain — `Deep` asks for `Mid`'s statics, and a
// flat "is this class mid-fold" guard cut the fold there. `Mid`'s own frame
// later overwrote its truncated entry, but `Deep`'s was already memoized with
// nothing inherited, so `Deep.f` stayed a TS2339 for the rest of the run.
//
// Only a re-entry that runs back through `extends` edges the WHOLE way is an
// actual cycle; this one arrives through a member edge and must fold normally.
// Which demand lands inside the window is a partition accident, so outline's
// `typeof Document` / `typeof Collection` / … lost `findAll`, `findOne` and
// `scope` at four checkers while keeping them at one.

export function open(): number {
  return Mid.f();
}

class Base {
  static f(): number {
    return 1;
  }
  static probe() {
    return Deep.f();
  }
}

class Mid extends Base {}

class Deep extends Mid {}

export const a: number = Mid.f();
export const b: number = Deep.f();
export const c: number = Base.probe();
