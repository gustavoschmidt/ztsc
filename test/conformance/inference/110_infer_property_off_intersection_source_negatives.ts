// Negatives for 109: the binder must be the intersection's property type, not
// `unknown` and not `never`. Assigning it to `boolean` prints what it is, so a
// regression in either direction moves the snapshot.

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

// The inferred type, printed.
declare const a: Pick1<HasRef & HasId>;
export const a1: boolean = a;

// A name NO constituent declares still misses — the pattern must not be
// satisfied by an index signature or an apparent `Object` member.
type PickMissing<P> = P extends { nope?: infer N | undefined } ? N : "NOMATCH";
declare const b: PickMissing<HasRef & HasId>;
export const b1: boolean = b;

type PickToString<P> = P extends { toString?: infer T | undefined } ? T : "NOMATCH";
declare const c: PickToString<HasRef & HasId>;
export const c1: boolean = c;

// A required pattern property is NOT satisfied by an optional source property,
// intersection or not.
type PickReq<P> = P extends { id: infer I } ? I : "NOMATCH";
declare const d: PickReq<HasRef & HasId>;
export const d1: boolean = d;
