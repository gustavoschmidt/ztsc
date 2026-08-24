// A constraint that reads back through the parameter it constrains. Resolving
// it evaluates `T["hello"]`, whose index check asks for T's constraint —
// which is still resolving, so `tp_constraint_cache` (written on the way out)
// has nothing to answer with and the resolution re-entered forever.
//
// tsc cuts with `pushTypeResolution(tp, Constraint)` and reports TS2313;
// ztsc takes the same cut, answering "no constraint". Its own TS2313 reads
// the parameter list SYNTACTICALLY, and a constraint spelled as an indexed
// access is not on that chain, so the oracle's stays in DEFERRED.
interface Foo {
    hello: boolean;
}

export function viaIndexedAccess<T extends Foo | T["hello"]>(): void {}

// The same shape one hop longer, through a second parameter's constraint.
export function viaSecondParam<T extends U["hello"], U extends Foo | T>(): void {}
