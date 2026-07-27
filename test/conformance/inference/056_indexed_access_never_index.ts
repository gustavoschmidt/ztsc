// `T[never]` is `never`, not `any`. `keyof {}` is `never`, so an indexed access
// over an empty interface has an empty key set and contributes nothing to a
// union that contains it. Falling back to the "index not found" `any` poisoned
// the whole union — the shape @types/react uses to build `ReactNode`, which
// therefore accepted anything and made every ReactNode-contextual callback
// parameter an implicit any.
interface Empty {}

type N = string | Empty[keyof Empty];

declare const n: N;
// `N` is exactly `string`: a number is not assignable to it, and it is
// assignable to `string`.
const okStr: string = n;
const badNum: number = n;

declare const anything: { z: 1 };
const badObj: N = anything;

// The access on its own is `never`.
type E = Empty[keyof Empty];
declare const e: E;
const okNever: never = e;
const badFromString: E = "s";

// A non-empty key set is unaffected.
interface Rec {
  id: number;
}
type R = string | Rec[keyof Rec];
declare const r: R;
const okNumIntoR: R = 1;
const badBoolIntoR: R = true;
