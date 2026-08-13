// A type parameter default that names the type it is declared on. Filling the
// default materializes that reference, which fills the same default again —
// `fixTypeArgs` recursed until the stack died. tsc cuts with
// `pushTypeResolution(tp, Default)` and reports TS2716; ztsc takes the same
// cut and answers `any` for the parameter (it has no TS2716 of its own, so
// the oracle's is recorded in DEFERRED).
interface SelfReference<T = SelfReference> {}

// Mutually circular defaults, which the single-parameter check alone does not
// catch: filling A's default needs B's, which needs A's.
interface PingA<T = PingB> {}
interface PingB<T = PingA> {}

declare const s: SelfReference;
declare const a: PingA;
export const used: [typeof s, typeof a] = [s, a];
