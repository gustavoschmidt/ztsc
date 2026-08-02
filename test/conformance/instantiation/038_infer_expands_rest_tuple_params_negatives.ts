// The expansion produces a real parameter list, so the resulting bound
// function is still arity- and type-checked.

interface Elem {
  innerHTML: string;
  tagName: string;
}
type Matcher = string | RegExp;

type BoundFunction<T> = T extends (container: Elem, ...args: infer P) => infer R
  ? (...args: P) => R
  : never;

declare const bound: BoundFunction<(...args: [Elem, Matcher, number]) => Elem>;

// Too few arguments.
export const tooFew = bound("id");

// Too many.
export const tooMany = bound("id", 1, 2);

// Wrong argument type.
export const wrongType = bound(1, 2);

// The return type comes from the source signature, so a member it does not
// have is still a TS2339.
export const badMember = bound("id", 1).nope;

// A source whose first parameter does NOT match the pattern's still falls to
// the `never` branch — the expansion changes which types are compared, not
// whether the check happens. Nothing is assignable INTO `never`, so this
// reports exactly when the conditional took the false branch.
type Mismatch = BoundFunction<(...args: [number, Matcher]) => Elem>;
declare const anyFn: (id: Matcher) => Elem;
export const intoNever: Mismatch = anyFn;
