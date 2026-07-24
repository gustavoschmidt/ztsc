// Indexed access on an optional tuple element includes `undefined`
// ([x?: T][0] === T | undefined), matching tsc's getIndexedAccessType.
type T = [a?: string];
type A0 = T[0];
const ok1: string | undefined = null as any as A0;
const ok2: A0 = undefined;
const bad: string = null as any as A0;          // TS2322

// negative control: a REQUIRED element does NOT widen with undefined.
type R = [a: string, b?: number];
const rreq: string = null as any as R[0];
const ropt: number = null as any as R[1];       // TS2322 (optional -> |undefined)
