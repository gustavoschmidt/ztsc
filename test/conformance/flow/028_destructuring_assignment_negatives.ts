// Negatives around destructuring-assignment targets: a genuine
// use-before-assignment still reports, an unresolved target is still TS2304,
// and a constant / read-only target is still rejected.
declare function pair(): [number, number];
declare function rec(): { a: number; b: number };

// Read before the destructuring assignment that writes it.
let ub: number;
const bad: number = ub + 1;
[ub] = pair();

// Object form, same shape.
let ub2: number;
const bad2: number = ub2 + 1;
({ a: ub2 } = rec());

// Only one of the two targets is written before the read.
let only1: number, only2: number;
[only1] = pair();
const bad3: number = only1 + only2;

// The target name does not resolve.
[notDeclaredHere] = pair();
({ a: alsoNotDeclared } = rec());

// Constant targets.
const cst = 1;
[cst] = pair();
const cst2 = 2;
({ a: cst2 } = rec());

// Read-only property target.
declare const ro: { readonly p: number };
[ro.p] = pair();
