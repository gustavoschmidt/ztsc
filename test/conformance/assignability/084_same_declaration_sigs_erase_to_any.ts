// Two instantiations of ONE generic declaration relate with their type
// parameters erased to `any`, not to their constraints.
//
// tsc's `signaturesRelatedTo` has three arms and only the middle one compares
// a generic signature un-erased. When both sides are instantiations of the
// same symbol it walks them pairwise through `signatureRelatedTo(…, erase =
// true)`, i.e. `getErasedSignature` — `createTypeEraser`, every own type
// parameter mapped to `any`. Erasing `S` to its CONSTRAINT instead compares
// `'t0.0' | … | 't1.9'` against `'t0.0' | … | 't0.9'`, whose covariant return
// positions do not relate, and the pair is rejected with the tell-tale
// message "Type '<S>(x: S) => S' is not assignable to type '<S>(x: S) => S'".
//
// It is also where a kysely builder chain's cost comes from: those
// constraints are unions over every column of every table in the schema, so
// one such comparison substitutes the whole schema into a mapped return type.
type D = '0' | '1' | '2' | '3' | '4' | '5' | '6' | '7' | '8' | '9';

// A function-valued PROPERTY, so strictFunctionTypes applies and the
// comparison is not the bivariant method one.
interface Builder<TB extends string> {
  pick: <S extends `${TB}.${D}`>(x: S) => S;
}

declare const wide: Builder<'t0' | 't1'>['pick'];
export const narrow: Builder<'t0'>['pick'] = wide;

// Negative control: DIFFERENT declarations are not the erase-to-`any` case,
// so a constrained generic target still rejects a concrete source.
export const bad: <T extends string>(x: T) => T = (x: '000') => x;
