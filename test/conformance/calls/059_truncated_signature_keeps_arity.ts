// A signature whose instantiation TRUNCATES must not be read back as a
// signature of ARITY ZERO.
//
// `instantiateId`'s depth/count guard fires before its `.function` arm runs
// and returns `error_type` for the whole signature; every `fn*` accessor then
// reports that as zero parameters, so `checkCallArguments` said "Expected 0
// arguments, but got 1" about a call whose substitution merely ran out of
// budget. tsc cannot reach that state — `instantiateSignature` clones the
// signature and instantiates each parameter and the return type
// independently, so a limit hit degrades a COMPONENT while the shape (arity,
// optionality, `this`) always survives. A truncation has no opinion about
// arity, so the claim is withdrawn.
//
// The shape is kysely's `ExpressionBuilder.selectFrom`, immich
// `src/repositories/album.repository.ts:56`, where it cost 16 TS2554 keys and
// (through the dropped `Selection<…>` output) a family of TS2339 on the
// aliased columns downstream.
//
// `burn`'s `S` is not inferable from its (empty) argument list, so it falls
// back to its constraint `W` and the mapped return crosses all 1,000 members
// of `W` with all 1,000 of `W2` — past the 250,000-node statement budget.
// That spends the budget inside the callback, so the ENCLOSING `pick` call's
// own substitution then trips immediately and comes back `error_type`.
//
// The remaining TS2589 is the truncation itself and is the documented budget
// divergence, not a regression: tsc's limit is 5,000,000 instantiations to
// ztsc's 250,000, so tsc completes this materialization and is clean here.
// See `src/checker/prof.zig` for why raising the budget is not the trade it
// looks like. What this fixture pins is that the truncation costs exactly
// that one diagnostic and does not also invent an arity error.
type D = '0' | '1' | '2' | '3' | '4' | '5' | '6' | '7' | '8' | '9';
type W = `${D}${D}${D}`;
type W2 = `${D}${D}${D}`;

type Cross<K, U> = U extends string ? `${K & string}.${U}` | `${U}.${K & string}` : never;

interface Builder<O> {
  pick<S extends W>(cb: (b: Builder<O>) => unknown): Builder<O & { [K in S]: Cross<K, W2> }>;
  burn<S extends W>(): Builder<O & { [K in S]: Cross<K, W2> }>;
}

declare const qb: Builder<{}>;
export const out = qb.pick((b: Builder<{}>) => b.burn());
