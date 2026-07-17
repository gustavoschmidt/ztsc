// Return-position `void` vs a union target containing `void`.
// tsc accepts `void` against `void | undefined` (either member order) via the
// union's `void` member — the same relation the direct-assignment path uses.
// The covariance exemption ("void target return accepts any source") applies
// only to an *exact* `void` return, not to a union that merely contains it.

declare const v: void;
declare const u: undefined;

// direct-assignment control cases
const d1: void | undefined = v; // ok
const d2: void | undefined = u; // ok
const d3: undefined = v; // TS2322: void is not assignable to undefined

type RvoidU = () => void | undefined;
type RundefV = () => undefined | void;
type Rvoid = () => void;
type Rundef = () => undefined;
type Rnum = () => number;
type Runknown = () => unknown;
type Rany = () => any;

// void source return vs union-containing-void target — the bug: accepted
const a1: RvoidU = (): void => {}; // ok
const a2: RundefV = (): void => {}; // ok
// undefined source vs the same union — accepted
const a3: RvoidU = (): undefined => undefined; // ok
// void source vs exact void / unknown / any targets — accepted
const a4: Runknown = (): void => {}; // ok
const a5: Rany = (): void => {}; // ok
// exact-void target exempts any source return
const a6: Rvoid = (): number => 1; // ok

// non-void source vs union-containing-void — NOT exempt, rejected
const a7: RvoidU = (): number => 1; // TS2322
const a8: RvoidU = (): unknown => 1; // TS2322
// void source vs bare undefined / number targets — rejected
const a9: Rundef = (): void => {}; // TS2322
const a10: Rnum = (): void => {}; // TS2322
