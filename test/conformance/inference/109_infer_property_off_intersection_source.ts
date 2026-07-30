// tsc's `inferFromProperties` reads each pattern property off the source with
// `getTypeOfPropertyOfType`, and `getUnionOrIntersectionProperty` synthesises
// an INTERSECTION's property from the constituents that declare it. So a
// pattern property matches an intersection source whenever any constituent
// declares that name — the binder does not fall back to `unknown`.
//
// React's `PropsWithRef` needs exactly this: `ComponentProps<'div'>` is
// `ClassAttributes<HTMLDivElement> & HTMLAttributes<HTMLDivElement>`, so
// `P extends { ref?: infer R | undefined }` sees `ref` only through the
// intersection.

interface Elem {
  tagName: string;
}
interface HasRef {
  ref?: ((instance: Elem | null) => void) | null | undefined;
}
interface HasId {
  id?: string | undefined;
}

type Pick1<P> = P extends { ref?: infer R | undefined } ? R : "NOMATCH";

// One constituent declares it.
declare const a: Pick1<HasRef & HasId>;
export const a1: ((instance: Elem | null) => void) | null | undefined = a;

// Both constituents declare it.
type Both = { tag?: "x" | undefined } & { tag?: "x" | undefined };
type PickTag<P> = P extends { tag?: infer T | undefined } ? T : "NOMATCH";
declare const c: PickTag<Both>;
export const c1: "x" | undefined = c;

// Signature inference through an intersection whose callable constituent
// carries the signature still works (unchanged path).
type Ret<F> = F extends { call1(): infer R } ? R : "NOMATCH";
declare const d: Ret<{ call1(): number } & { other: string }>;
export const d1: number = d;

// A required property in the pattern against an intersection source.
type PickReq<P> = P extends { id: infer I } ? I : "NOMATCH";
declare const e: PickReq<{ id: number } & { other: string }>;
export const e1: number = e;
