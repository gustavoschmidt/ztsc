// `in`/`out` are type-parameter modifiers only on a class, interface, or type
// alias (TS1274 everywhere else), `in` precedes `out` (TS1029), and `out` is
// still a plain identifier when no name follows it.

interface I<in T, out U> {
    f(x: T): U;
}
class C<in T, out U> {
    constructor(readonly f: (x: T) => U) {}
}
type A<in T, out U> = (x: T) => U;

function f<in T>(x: T): T {
    return x;
}
declare function g<out T>(x: T): T;
type FnType = <in T>(x: T) => T;
type CtorType = new <out T>(x: T) => T;
class D {
    m<in T>(x: T): T {
        return x;
    }
}
interface Order<out in T> {
    get(): T;
    set(v: T): void;
}

// No name follows, so `out` names the parameter here.
interface Named<out> {
    v: out;
}
type NamedAlias<out> = out;
