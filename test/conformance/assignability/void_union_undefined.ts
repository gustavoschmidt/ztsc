// `undefined` is assignable to `void` (tsc `isSimpleTypeRelatedTo`: `s &
// Undefined && t & (Undefined | Void)`), and a UNION source is related
// constituent-wise — so `void | undefined`, what an optional-void return
// annotation and a `.then()` callback both produce, is assignable to `void`.
declare const vu: void | undefined;
declare const un: undefined;
declare const vv: void;
declare const nu: null;
declare const sv: string | void;

export const a1: void = vu;
export const a2: void = un;
export const a3: void = vv;
export const a4: void | undefined = vv;
export const a5: void | undefined = vu;
export const a6: void | number = vu;
export const a7: undefined = vv; // void is not undefined
export const a8: void = nu; // null is not void (strictNullChecks)
export const a9: void = sv; // the string constituent is not void

type MaybeVoid = void | undefined;
declare const mv: MaybeVoid;
export const b1: void = mv;

declare function g(): void | undefined;
export const c1: () => void = g;
declare function h(x: void): void;
export const c2 = h(vu);
export const c3 = h(un);
export const c4 = h(nu); // null is not void
