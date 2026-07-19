// NEGATIVE: BooleanConstructor has no type predicate, so `filter(Boolean)`
// does not narrow (matches tsc/tsgo).
const xs: (number | null)[] = [1, null, 2];
const ys = xs.filter(Boolean);
const n: number[] = ys;
