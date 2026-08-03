// A conditional whose UNUSED branch is deeper than the instantiation-
// depth limit. The check resolves to the true branch, so the deep false
// branch is never substituted and nothing reports TS2589 (tsc, which
// only instantiates the branch its check selects, is clean here too).
type P<A> = A extends string ? number : [[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[A]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]];
declare const v: P<string>;
export const got: number = v;
