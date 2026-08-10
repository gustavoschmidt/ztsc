// The other half of 064: a reference a closure genuinely CAPTURES still
// continues into the definition-point flow, so an enclosing narrowing survives
// the closure boundary (tsc narrows `const` and never-reassigned locals across
// a function expression / arrow). Only the last block errors, and it errors for
// an unrelated reason: `u` is assigned AFTER the closure, so the reference is
// not past its last assignment (TS 5.4's `isPastLastAssignment`) and no
// narrowing crosses the boundary at all — the limit that keeps the capture
// rule from over-applying. The other side of that rule — an assignment BEFORE
// the closure, which does still cross — is flow/071.
declare function run<T>(cb: () => T): T;
declare function runWith<T>(cb: (v: number) => T): T;

function captured(x: string | null) {
  if (x === null) return '';
  // `x` is a never-reassigned parameter: narrowed to `string` across the arrow.
  return run(() => x.toUpperCase());
}

function capturedConst(y: string | undefined) {
  const z = y;
  if (z === undefined) return '';
  return run(function () {
    return z.toUpperCase();
  });
}

// Capture survives even when the closure declares OTHER bindings.
function capturedAlongsideOwn(w: number | null) {
  if (w === null) return 0;
  return runWith((other) => w + other);
}

// A local assigned again AFTER the closure keeps its declared type inside it.
function capturedAssignmentNarrowed() {
  let u: string | undefined;
  u = 'text';
  const r = run(() => u);
  u = undefined;
  return r;
}
const s: string = capturedAssignmentNarrowed();

export { captured, capturedConst, capturedAlongsideOwn, s };
