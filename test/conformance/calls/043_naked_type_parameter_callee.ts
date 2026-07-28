// Calling a naked type parameter resolves against its APPARENT type.
//
// `resolveStructural` deliberately leaves a `.type_param` alone — walking to
// the constraint is `transitiveBaseConstraint`'s job — so the callee-kind
// switch saw `.type_param`, fell to its `else`, and reported TS2349 for every
// `<T extends (…) => R>(fn: T) => fn(…)`. tsc's `resolveCallExpression` calls
// `getApparentType` on the callee before it looks for signatures.

export const nullary = <T extends () => number>(fn: T) => fn();
export const unary = <T extends (x: number) => number>(fn: T) => fn(1);
export const anyRest = <T extends (...args: any[]) => any>(fn: T) => fn(1, 2);
export const anyRestEmpty = <T extends (...args: any[]) => any>(fn: T) => fn();
export const typedRest = <T extends (...args: number[]) => string>(fn: T) =>
  fn(1, 2);

// The constraint's signature is checked, not waved through: arity and argument
// types still apply.
export const wrongArity = <T extends (x: number) => number>(fn: T) => fn();
export const wrongArg = <T extends (x: number) => number>(fn: T) => fn("s");

// A transitive constraint chain resolves the whole way.
export const chained = <F extends () => number, T extends F>(fn: T) => fn();

// A constraint that is not callable is still not callable.
export const notCallable = <T extends { x: number }>(fn: T) => fn();

// An unconstrained parameter has no apparent call signature either.
export const unconstrained = <T>(fn: T) => fn();

// `new` through a type parameter, same rule. (The negative — `new` on a
// call-only constraint — is left out: ztsc reports TS2351 there and the oracle
// TS7009, a code divergence that has nothing to do with this rule.)
export const constructed = <T extends new () => { x: number }>(C: T) => new C();

// A constraint that is an intersection carrying the call signature on one
// member.
export const viaIntersection = <T extends (() => number) & { tag: string }>(
  fn: T,
) => fn();
