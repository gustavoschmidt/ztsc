// The other half of 064: a reference a closure genuinely CAPTURES still
// continues into the definition-point flow, so an enclosing narrowing survives
// the closure boundary (tsc narrows `const` and never-reassigned locals across
// a function expression / arrow). Only the last block errors, and it errors for
// an unrelated reason: `u` is reassigned, so it is not an effectively-const
// local and no narrowing crosses the closure at all — the boundary that keeps
// the capture rule from over-applying.
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

// An assignment-narrowed `unknown` local is still captured correctly.
function capturedAssignmentNarrowed() {
  let u: unknown;
  u = 'text';
  return run(() => u);
}
const s: string = capturedAssignmentNarrowed();

export { captured, capturedConst, capturedAlongsideOwn, s };
