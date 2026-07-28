// A candidate found in a PARAMETER position is contravariant evidence and is
// collected apart from the covariant set (tsc's `inferFromContravariantTypes`
// / `InferenceInfo.contraCandidates`). At the end, `getInferredType` prefers
// the contravariant side: the covariant inference survives only when it is not
// `never` and is a SUBTYPE of a contravariant candidate — i.e. when every
// parameter position the variable appears in would still accept it. Otherwise
// the parameter takes the contravariant candidates' common SUBtype
// (`getCommonSubtype`), the narrowest type all of those positions can be fed.
//
// Pooled into one accumulator, a callback's parameter type and the value the
// call produces were unioned together, and the union then satisfied neither
// side: `useThing(num, setNum)` came out `number | ((p: number) => number)`.

declare const s: string;
declare const n: number;
declare const cbS: (x: string) => void;
declare const cbSN: (x: string | number) => void;
declare const cbU: (x: unknown) => void;

// Only contravariant evidence: the parameter type is the inference.
declare function k1<T>(cb: (x: T) => void): T;
const onlyS: string = k1(cbS);
const onlySN: string | number = k1(cbSN);

// Two contravariant candidates fold to their common SUBtype, either order.
declare function k2<T>(a: (x: T) => void, b: (x: T) => void): T;
const subA: string = k2(cbS, cbSN);
const subB: string = k2(cbSN, cbS);
const subC: string = k2(cbU, cbS);

// Covariant and contravariant together: the covariant inference wins when it
// is a subtype of the contravariant candidate.
declare function k3<T>(v: T, cb: (x: T) => void): T;
const covWins: string = k3(s, cbSN);
const covSame: string = k3(s, cbS);

// A callback whose parameter is a UNION containing a function of the same
// variable — React's `Dispatch<SetStateAction<E>>` — used to union its whole
// parameter type into the covariant set.
type Setter<E> = (v: E | ((p: E) => E)) => void;
declare function useThing<T>(value: T, set: Setter<T>): T;
declare const setNum: Setter<number>;
const stateIsNumber: number = useThing(n, setNum);

// A `reduce`-shaped call must be untouched: the callback's accumulator
// parameter is typed FROM the partial inference, so reading it back as a
// contravariant candidate would just be our own guess coming home.
declare const xs: readonly number[];
const summed: number = xs.reduce((acc, x) => acc + x, 0);
const strung: string[] = xs.reduce((acc, x) => acc.concat(String(x)), [] as string[]);

// A METHOD's parameters are bivariant, so nothing below one is contravariant.
interface M<T> {
  m(cb: (x: T) => void): T;
}
declare const m1: M<string>;
const method: string = m1.m(cbSN);

// NEGATIVE: when the covariant candidate is not a subtype of the contravariant
// one, the contravariant side wins and the covariant argument is rejected.
const clash = k3(n, cbS);
