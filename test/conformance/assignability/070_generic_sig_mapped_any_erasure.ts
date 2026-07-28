// Two generic signatures whose parameters carry a MAPPED type over the
// signature's own type parameter: the constraint erasure leaves `Pick<S, K>`
// deferred and the relation fails, but tsc's `getErasedSignature` maps K to
// `any`, and a mapped type over `any` demands nothing — so the relation holds.
type Full = { a: number; b: number; c: number };
type Ui = Omit<Full, "c">;

declare class Comp<S> {
  setState<K extends keyof S>(
    state: ((prev: Readonly<S>) => Pick<S, K> | S | null) | Pick<S, K> | S | null,
    cb?: () => void,
  ): void;
}
declare const fromApp: Comp<Full>["setState"];
export const asProp: Comp<Ui>["setState"] = fromApp; // OK

// The mapped type may sit anywhere in the parameter's union.
declare class C2<S> {
  m<K extends keyof S>(state: ((prev: Readonly<S>) => S | null) | Pick<S, K>): void;
}
declare const f2: C2<Full>["m"];
export const g2: C2<Ui>["m"] = f2; // OK

// NEGATIVE: no mapped type anywhere, so the retry does not apply and the
// contravariant mismatch is still reported.
declare class C3<S> {
  m(state: ((prev: Readonly<S>) => S | null) | S | null): void;
}
declare const f3: C3<Full>["m"];
export const g3: C3<Ui>["m"] = f3;

// NEGATIVE: a plain function type is unaffected.
declare const f4: (state: Full) => void;
export const g4: (state: Ui) => void = f4;
