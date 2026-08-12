// A signature type parameter's bound may name a SIBLING declared after it.
// Reading such a signature off an INSTANTIATED generic interface freshens the
// sibling (its default moved under the receiver's substitution) but leaves the
// earlier bound naming the sibling's original declaration symbol — a dangling
// reference that keeps `Cond<U>` from ever reducing, so no argument is
// assignable to it and the call is rejected outright.
//
// i18next's `TFunction` is the shape this was found on: every two-argument
// `t(key, {opts})` in outline was a TS2769.

type Cond<N> = N extends "q" ? "q" : string;

interface Tagged<A = "translation"> {
  <K extends Cond<U>, U = A>(key: K | K[], opts: object): K;
}

declare const tagged: Tagged;

// `U` is freshened (its default `A` is substituted); `K`'s bound must still
// see it. `K` infers as `"hello"`, so this is an error about `"hello"`, not
// about an unreduced conditional.
const a: number = tagged("hello", {});

// Same, one level deeper: the interface parameter is itself defaulted from
// another parameter of the interface.
interface Tagged2<N = "translation", A = N extends null ? "translation" : N> {
  <K extends Cond<U>, U = A>(key: K | K[], opts: object): K;
}
declare const tagged2: Tagged2;
const b: number = tagged2("hello", {});

// The FORWARD direction was already handled (the bound names an EARLIER
// sibling, which the freshening loop rewrites as it walks) and must stay so.
interface Tagged3<A = "translation"> {
  <U = A, K extends Cond<U> = Cond<U>>(key: K | K[], opts: object): K;
}
declare const tagged3: Tagged3;
const c: number = tagged3("hello", {});

// No freshening at all: the bound names a later sibling whose default is a
// plain literal, so nothing is minted and nothing needs repairing.
declare function plain<K extends Cond<U>, U = "translation">(key: K | K[], opts: object): K;
const d: number = plain("hello", {});
