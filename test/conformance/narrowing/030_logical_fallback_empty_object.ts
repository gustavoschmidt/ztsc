// `x ?? {}` / `x || {}`: the empty-object fallback branch must not absorb the
// other member (tsc's strictSubtypeRelation never lets an empty anonymous
// object type win the subtype reduction) — but `{}` itself IS absorbed by an
// index-signature member it's mutually assignable with.
declare const attrs0: { [x: string]: number } | undefined;
const attrs = attrs0 ?? {};
const v1 = attrs.full_name;      // reduces to the indexed type: ok

declare const w0: { name: string } | undefined;
const w = w0 ?? {};
const v2 = w.name;               // union kept: TS2339 on the {} member

declare const u0: { url?: string } | undefined;
const u = u0 || {};
const v3 = u.url;                // {} absorbed by { url?: string }: ok

void v1; void v2; void v3;
