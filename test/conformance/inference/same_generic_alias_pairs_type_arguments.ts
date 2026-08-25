// tsc's `inferFromTypes` opens with: "source and target are types originating
// in the same generic type alias declaration — simply infer from source type
// arguments to target type arguments" (`source.aliasSymbol ===
// target.aliasSymbol`). A FUNCTION-bodied alias needs it as much as an object
// one: the walk it replaces descends into the signature and infers out of
// whatever the parameter types happened to REDUCE to.
//
// react-query's shape, reduced. `QFC<K, P>` is a conditional on `P`, so the
// target's `QF<T, K, P>` carries it still DEFERRED while the source's
// `QF<R, string[], never>` has already collapsed to the true branch. Walking
// the signature pairs the deferred conditional against that branch and binds
// `P` to its `pageParam?: unknown`; pairing the alias arguments binds the
// written `never`. Oracle-pinned (tsgo 7.0.2): the first call infers `never`,
// the second — spelled STRUCTURALLY, so it carries no alias identity —
// infers `unknown`, and that difference is the whole rule.

type R = { r: 1 };
type QFC<K, P = never> = [P] extends [never]
    ? { k: K; pageParam?: unknown; direction?: unknown }
    : { k: K; pageParam: P; direction: "f" | "b" };
type QF<T, K, P = never> = (c: QFC<K, P>) => T;

interface B<T, K, P = never> { k: K; queryFn?: QF<T, K, P> }
declare function g<T, K, P = never>(o: B<T, K, P>): P;

interface Aliased { k: string[]; queryFn?: QF<R, string[], never> }
interface Raw {
    k: string[];
    queryFn?: (c: { k: string[]; pageParam?: unknown; direction?: unknown }) => R;
}

// The INTERSECTION argument is what exposes it: a plain `B<…>` argument pairs
// positionally at the top level and never reaches the members.
declare const a: Aliased & { extra: 1 };
declare const b: Raw & { extra: 1 };

const ra: never = g(a);
const rb: never = g(b); // TS2322 — `unknown` is not `never`
