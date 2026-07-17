// An interface extending a type alias that resolves to an INTERSECTION must
// inherit every constituent's members. ztsc previously flattened the base to
// nothing (mergeBaseObject dropped a non-object intersection base), so the
// interface read as empty — the clean assignment and member accesses below all
// spuriously errored (TS2353 excess + TS2339 on `.a`/`.b`).
type A = { a: string };
type B = { b: number };
type AB = A & B;
interface I extends AB {}
const ok: I = { a: "s", b: 1 };
const na: string = ok.a;
const nb: number = ok.b;
