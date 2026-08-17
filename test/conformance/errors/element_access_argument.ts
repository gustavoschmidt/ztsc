// `a[]` is TS1011 ("An element access expression should take an argument."),
// reported on the `]` rather than the generic "Expression expected" a missing
// operand would otherwise earn. It is a PARSE diagnostic, so it silences the
// grammar pass for the whole file — which is why the `const` class member that
// would draw TS1248 lives in its own case next door.
declare const arr: number[];

const bad = arr[];
const alsoBad = arr?.[];
