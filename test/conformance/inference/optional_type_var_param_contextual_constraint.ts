// A parameter that IS a still-un-inferred type variable contextually types its
// argument by the variable's CONSTRAINT (tsc's
// `getApparentTypeOfContextualType`, which takes the base constraint of a type
// variable before looking for a call signature). An OPTIONAL such parameter is
// `T | undefined` by the time the contextual type is built, so the variable
// arrives as a union member — and it must take the same route there, or the
// contextual type collapses to `undefined`, the callback argument gets no
// signature, and every one of its parameters is an implicit `any`.
//
// vitest's `fn<T extends Procedure = Procedure>(implementation?: T)` is the
// shape: immich's test doubles pass a bare `(event, callback: any) => …` to it.

type Procedure = (...args: any[]) => any;
interface Mock<T extends Procedure = Procedure> {
  tag: T;
}

declare function required<T extends Procedure>(impl: T): Mock<T>;
declare function requiredDefaulted<T extends Procedure = Procedure>(impl: T): Mock<T>;
declare function optional<T extends Procedure>(impl?: T): Mock<T>;
declare function optionalDefaulted<T extends Procedure = Procedure>(impl?: T): Mock<T>;

const a = required((event, callback: any) => callback(event));
const b = requiredDefaulted((event, callback: any) => callback(event));
const c = optional((event, callback: any) => callback(event));
const d = optionalDefaulted((event, callback: any) => callback(event));
const e = optionalDefaulted();

// A constraint that says no more than the placeholder leaves the parameter
// genuinely implicit.
declare function unconstrained<T>(impl?: T): T;
const f = unconstrained((event) => event); // TS7006

// The constraint is still only a fallback: an ARGUMENT-shaped constraint that
// names concrete parameter types wins, and the inferred `T` is the argument's
// own type, not the constraint.
type Handler = (name: string, count: number) => boolean;
declare function handler<T extends Handler>(impl?: T): T;
const g = handler((name, count) => name.length === count);
const gBad: string = g('x', 1); // TS2322

// A union parameter whose non-variable members carry the call signature is
// unchanged: the concrete member is what types the callback.
declare function mixed<T extends string>(impl?: T | ((n: number) => void)): void;
mixed((n) => {
  const m: number = n;
  return m;
});
