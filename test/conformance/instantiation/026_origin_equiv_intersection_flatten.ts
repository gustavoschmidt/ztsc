// Origin-tag equivalence through callable-object-intersection FLATTENING.
//
// A generic alias whose body is `Callable & { … }` (the shape of RTK's
// `AsyncThunk<Returned, Arg, Config>`) materializes to a KEPT intersection,
// not a plain object. Two route-divergent instantiations of it can carry
// DIFFERENT-but-EQUAL config args: one the unreduced `P & Omit<Base, keyof P>`
// — which is `P & {}` — and the other the concrete `P`. tsc treats the two
// instantiations as identical.
//
// The origin table now tags the flattened intersection with its canonical
// `makeRef(sym, args)`, and the reflexive fast-path treats the arg pairs as
// EQUIVALENT when each pair is equal by TypeId identity OR by a SOUND
// reduction (`P & {} ≡ P`, compared by interned identity — never by mutual
// assignability). So the relation short-circuits before the deferred members
// (`GetRejectValue<Config>` etc.) can diverge non-confluently.
type Empty = {};
type Thunk<C> = { (arg: number): C } & { cfg: C; typePrefix: string };

type P = { a: number; b: string };
type Merged = P & Empty; // structurally identical to P

declare function reducers(x: Thunk<P>): void;

const madeMerged: Thunk<Merged> = null as any;
reducers(madeMerged); // OK — Thunk<P & {}> ≡ Thunk<P>

// Also reflexive across a value whose config is the concrete `P` directly.
const madeP: Thunk<P> = null as any;
reducers(madeP); // OK

// Negative control — the equivalence is IDENTITY-based, not a same-name
// shortcut. A genuinely different config (`b: number`, not `string`) does NOT
// reduce to `P` and must STILL be rejected.
type Q = { a: number; b: number };
const madeQ: Thunk<Q> = null as any;
reducers(madeQ); // TS2345
