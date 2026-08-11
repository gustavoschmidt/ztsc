// tsc's `inferFromMatchingTypes` runs TWICE over a union source paired with a
// union target: once with `isTypeOrBaseIdenticalTo`, then with
// `isTypeCloselyMatchedBy` — two instantiations of the SAME generic (same
// declaring symbol, or same alias symbol) are inferred as a pair and BOTH are
// struck off. Only what is left reaches `inferToMultipleTypes`.
//
// React 19's `Ref<T> = RefCallback<T> | RefObject<T | null> | null` is the
// shape that needs it. Handing the whole argument union to each target
// constituent loses the callback arm entirely — a union is not a function —
// so `T` took only the object ref's type instead of tsc's `any`.
//
// Every `Unrelated` annotation below is the discriminator: it accepts `T =
// any` and rejects any concrete `T`.

interface RefObj<T> {
    current: T;
}
// The bivariance hack: a METHOD, so its parameter infers covariantly and the
// `any` it carries becomes a covariant candidate that wins the fold.
type RefCb<T> = { bivarianceHack(instance: T | null): void }["bivarianceHack"];
type R<T> = RefCb<T> | RefObj<T | null> | null;

type Unrelated = { zzzzz: string };

declare function mergeRefs<T>(refs: (R<T> | undefined)[]): R<T>;

declare const anyCb: (node: any) => void;
declare const objRef: RefObj<{ aaaaa: number }> | undefined;
declare const objRef2: RefObj<{ aaaaa: number }>;

// The `RefObj` arm pairs off by symbol, leaving the callback for `RefCb<T>`,
// whose `any` parameter common-supertypes the object candidate: `T` is `any`.
export const merged: R<Unrelated> = mergeRefs([anyCb, objRef]);
// Order-independent, and independent of the optionality of the object arm.
export const flipped: R<Unrelated> = mergeRefs([objRef, anyCb]);
export const required: R<Unrelated> = mergeRefs([anyCb, objRef2]);

// The same without the array wrapper: a bare union argument.
declare function one<T>(x: R<T> | undefined): R<T>;
export const single: R<Unrelated> = one(anyCb);
declare const cbOrObj: ((node: any) => void) | RefObj<{ aaaaa: number }>;
export const fromUnion: R<Unrelated> = one(cbOrObj);

// A PLAIN callback's parameter is contravariant, so its `any` is a
// contravariant candidate and `getInferredType` prefers the covariant object
// answer — `T` really is `{ aaaaa: number }` here, so `Unrelated` is an error
// and the object annotation is not.
type RefCbPlain<T> = (instance: T | null) => void;
type RPlain<T> = RefCbPlain<T> | RefObj<T | null> | null;
declare function mergePlain<T>(refs: (RPlain<T> | undefined)[]): RPlain<T>;
export const plainBad: RPlain<Unrelated> = mergePlain([anyCb, objRef]);
export const plainOk: RPlain<{ aaaaa: number }> = mergePlain([anyCb, objRef]);

// The pairing must stay narrow: `Iterator.next()` returns
// `IteratorYieldResult<T> | IteratorReturnResult<TReturn>`, and offering
// `IteratorReturnResult<void>` to `IteratorYieldResult<T>` would pair their
// `value` properties and infer `T = void`. Only same-symbol pairs infer.
declare class Seg {
    text: string;
}
declare function segments(): Generator<Seg, void, void>;
export const texts: string[] = Array.from(segments()).map(s => s.text);
