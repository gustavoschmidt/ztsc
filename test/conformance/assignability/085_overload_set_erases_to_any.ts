// An overload SET on either side is tsc's other `erase = true` position.
//
// `signaturesRelatedTo`'s last arm — anything that is not one-signature-
// against-one-signature and not two instantiations of the same symbol —
// cross-matches every source signature against every target signature through
// `signatureRelatedTo(…, erase = true)`, so both sides' own type parameters
// go to `any`. Erasing them to their CONSTRAINTS instead compares
// `'a.0' | … | 'a.9'` against `'b.0' | … | 'b.9'` and rejects the pair.
type D = '0' | '1' | '2' | '3' | '4' | '5' | '6' | '7' | '8' | '9';

interface Src {
  f: {
    <S extends `a.${D}`>(x: S): S;
    (x: number): number;
  };
}
interface Tgt {
  f: <S extends `b.${D}`>(x: S) => S;
}

declare const s: Src['f'];
export const t: Tgt['f'] = s;

// Negative control: one signature on each side is NOT erased — the source is
// instantiated in the target's context — so a genuinely wrong return type is
// still caught.
declare const single: <S extends `a.${D}`>(x: S) => number;
export const u: Tgt['f'] = single;
