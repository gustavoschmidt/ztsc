// A tuple with no rest element has a LITERAL `length`: the union of every
// arity it admits. Only a rest element makes it `number`.
type L0 = [];
type L1 = [a: number];
type L2 = [a: number, b?: string];
type L3 = [a?: number, b?: string];
type L4 = [a: number, ...rest: string[]];
type L5 = [a?: number, ...rest: string[]];

declare const l0: L0["length"];
declare const l1: L1["length"];
declare const l2: L2["length"];
declare const l3: L3["length"];
declare const l4: L4["length"];
declare const l5: L5["length"];

export const r0: 0 = l0;
export const r1: 1 = l1;
export const r2: 1 | 2 = l2;
export const r3: 0 | 1 | 2 = l3;
export const r4: number = l4;
export const r5: number = l5;

// NEGATIVES: the union is exact, not widened.
export const n2: 2 = l2;
export const n3: 1 | 2 = l3;
export const n4: 1 = l4;

// The arity guard this powers: `Parameters<F>["length"] extends 0 | 1`.
declare const guard: <TFunction extends ((event: any) => void) | (() => void)>(
  func: Parameters<TFunction>["length"] extends 0 | 1 ? TFunction : never,
) => TFunction;

export const g1 = guard((opts?: { reset: boolean }) => {
  void opts;
});
export const g2 = guard(() => {});
export const g3 = guard((e: number) => {
  void e;
});
