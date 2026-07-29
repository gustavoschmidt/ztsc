// `??` filters `void` out of its left operand along with `undefined` and
// `null`: tsc's `getNonNullableType` is `getTypeWithFacts(NEUndefinedOrNull)`,
// and `VoidFacts` does not carry `NEUndefinedOrNull`.
declare const cb: (t: number) => boolean | void;

export function onFrame(t: number): boolean {
  const shouldAbort = cb(t);
  return shouldAbort ?? false;
}

declare const bv: boolean | void;
export const a: boolean = bv ?? false;

// A bare `void` left operand leaves only the right operand.
declare const v: void;
export const b: number = v ?? 1;

// `void` alongside a nullish constituent.
declare const nv: string | void | undefined;
export const cc: string = nv ?? "x";

// The right operand still contributes: this is `boolean | number`.
export const d: boolean | number = bv ?? 1;
