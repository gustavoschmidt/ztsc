// BOUNDARY CASE for the mapped-key-set `infer` rule (see 047).
//
// tsc's `inferToMappedType` has two branches. 047 covers the one ztsc models:
// a key set that IS an inference target (`Record<infer N, V>`). This file
// covers the one it does not — the HOMOMORPHIC key set `{ [P in keyof U]: X }`,
// which tsc answers by synthesizing a REVERSE MAPPED TYPE. ztsc has no such
// type, so the binder is left UNOWNED and the conditional keeps its false
// branch (`never`), making every line below a deterministic under-report
// registered in DEFERRED.
//
// The point of the case is that the binder must not be owned. Owning it
// without matching resolves it to `unknown`, which relates to almost anything
// and flips the conditional to its TRUE branch with a meaningless value; and
// binding it to the source instead is only exact for the identity template and
// was measured to cost 47 false TS2352s on immich, where the resulting real
// types started exercising the comparable relation. Both directions are false
// positives on correct code; `never` is merely a missed error.

interface Repo {
  log(msg: string): void;
  level: number;
}

declare const anyv: any;

// Via `Pick<T, keyof T>` — the key set survives instantiation as a real
// `keyof U` constraint.
type RepositoryInterface<T extends object> = Pick<T, keyof T>;
type As<T> = T extends RepositoryInterface<infer U> ? U : never;

export const aBad: number = anyv as As<Repo>;

// Written syntactically — the key set is parked in the mapped SOURCE.
type Ident<T> = { [P in keyof T]: T[P] };
type AsIdent<T> = T extends Ident<infer U> ? U : never;

export const bBad: number = anyv as AsIdent<Repo>;

// A MODIFIER map, where binding the source would be outright wrong.
type AsPartial<T> = T extends Partial<infer U> ? U : never;
export const cBad: number = anyv as AsPartial<Repo>;

// A non-identity template, likewise.
type Boxed<T> = { [P in keyof T]: { v: T[P] } };
type AsBoxed<T> = T extends Boxed<infer U> ? U : never;
export const dBad: number = anyv as AsBoxed<{ a: { v: number } }>;
