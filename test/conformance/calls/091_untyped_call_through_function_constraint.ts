// tsc's `isUntypedFunctionCall` makes a call on anything assignable to the
// global `Function` — with no call and no construct signatures of its own —
// an UNTYPED call: `resolveUntypedCall` types it `any` and reports nothing.
//
//   !numCallSignatures && !numConstructSignatures &&
//   !(apparentFuncType.flags & Union) &&
//   !(getReducedType(apparentFuncType).flags & Never) &&
//   isTypeAssignableTo(funcType, globalFunctionType)
//
// A type parameter constrained by `Function` satisfies it — its APPARENT type
// is `Function` — which is what types React's `useNonReactiveCallback`/
// `useEvent` idiom. ztsc only recognised a callee whose own type was the
// `Function` reference, so every such body was TS2349.

export function useNonReactiveCallback<T extends Function = () => void>(fn: T): T {
  let ref = fn;
  return ((...args: any) => {
    const latest = ref;
    return latest(...args);
  }) as unknown as T;
}

// The result is `any`, so it flows anywhere.
export function callIt<T extends Function>(f: T): number {
  return f(1, 2, 3);
}

// A sub-constraint of `Function` works the same way.
interface Fnish extends Function {
  tag: string;
}
export function callSub<T extends Fnish>(f: T) {
  return f("x");
}

// A directly `Function`-typed value was already accepted; keep it that way.
export function callPlain(f: Function) {
  return f(1);
}

// --- what must still report -------------------------------------------------
// An unconstrained type parameter is not assignable to `Function`.
export function callUnconstrained<U>(u: U) {
  return (u as U)();
}

// A constraint that is a plain object is not `Function`.
export function callObject<T extends {a: number}>(t: T) {
  return t();
}

// A non-callable value is unchanged.
declare const o: {a: number};
export const bad = o();
