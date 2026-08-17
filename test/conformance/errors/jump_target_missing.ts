// A `break`/`continue` whose walk reaches the SOURCE FILE without meeting its
// target — as opposed to reaching a function first, which is TS1107 and lives
// in `jump_across_function_boundary.ts`. tsc has four wordings for it:
//
//   * TS1105 / TS1104 — an unlabeled `break` / `continue` with nothing to jump
//     to. A `switch` is a target for `break` and not for `continue`;
//   * TS1116 / TS1115 — a labeled one whose label names no enclosing
//     statement, and, for `continue` alone, one whose label names a statement
//     that is NOT an iteration.
declare const c: boolean;

break;
continue;

switch (0) {
  default:
    continue;
}

while (c) {
  break missing;
}
while (c) {
  continue missing;
}

notALoop: continue notALoop;

// All of these resolve, and say nothing.
outer: while (c) {
  inner: for (;;) {
    continue outer;
    break inner;
  }
}
chained: labelled: while (c) {
  continue chained;
}
block: {
  break block;
}
switch (1) {
  case 1:
    break;
}
