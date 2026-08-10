// tsc's `inferFromSignatures` pairs source and target signatures from the END:
//
//     const len = sourceLen < targetLen ? sourceLen : targetLen;
//     for (let i = 0; i < len; i++)
//       inferFromSignature(getBaseSignature(sourceSignatures[sourceLen - len + i]),
//                          getErasedSignature(targetSignatures[targetLen - len + i]));
//
// so a one-signature parameter infers from the source's LAST overload. ztsc
// already did that for a callable OBJECT (an interface with call signatures)
// but had no arm for an OVERLOAD SET — merged `declare function`
// declarations, which is what `console.error` becomes once @types/node's
// signatures merge with lib.dom's. Inference simply bailed, `Promise.catch`'s
// `TResult` was left at its DEFAULT `never`, the parameter printed as
// `((reason: any) => PromiseLike<never>) | null | undefined`, and every
// `.catch(console.error)` was TS2345.

declare function work(): Promise<void>;

declare function ovf(a: string): string;
declare function ovf(a: number): number;

// TResult comes from the LAST overload.
export const viaOverloadSet: Promise<void | number> = work().catch(ovf);
export const wrongOverload: Promise<void | string> = work().catch(ovf);

// The callable-object form, which already worked, answers identically.
interface Ov {
  (a: string): string;
  (a: number): number;
}
declare const ov: Ov;
export const viaCallableObject: Promise<void | number> = work().catch(ov);

// The `console.error` shape: three void-returning overloads, so the call is
// simply accepted.
declare function logLike(...data: any[]): void;
declare function logLike(message?: any, ...optionalParams: any[]): void;
declare function logLike(message?: any, ...optionalParams: any[]): void;
export const voidOverloads = work().catch(logLike);

// A plain function is unaffected.
declare const plain: (m?: any) => number;
export const viaPlain: Promise<void | number> = work().catch(plain);
