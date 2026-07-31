// TS 4.7 declaration-site variance. An `in`/`out` annotation relates two
// instantiations of the same generic by their type ARGUMENTS, not by their
// members — including pairs the structural walk rejects.

interface Getter<out T> {
    get(): T;
}
interface Setter<in T> {
    set(v: T): void;
}
interface Both<in out T> {
    get(): T;
    set(v: T): void;
}

declare const gs: Getter<string>;
const g1: Getter<unknown> = gs; // covariant: string -> unknown

declare const su: Setter<unknown>;
const s1: Setter<string> = su; // contravariant: the argument goes the other way

declare const bs: Both<string>;
const b1: Both<string> = bs; // invariant: identical arguments

// A method PARAMETER is bivariant, so `out` is satisfied there and the
// relation still goes by the annotation.
interface MethodParam<out T> {
    m(v: T): void;
}
const mp: MethodParam<unknown> = {} as MethodParam<string>;

// An unannotated parameter keeps the structural relation it always had.
interface Plain<T> {
    v: T;
}
const p1: Plain<unknown> = {} as Plain<string>;

// Mixed: the annotated parameter goes by variance, the unannotated one is
// identical on both sides.
interface Mixed<in A, B> {
    a(x: A): void;
    b: B;
}
const m1: Mixed<string, number> = {} as Mixed<unknown, number>;

// Nested one level: the argument pair is itself variance-related.
interface Wrap<out T> {
    v: T;
}
const w1: Wrap<Getter<unknown>> = {} as Wrap<Getter<string>>;

// A class carries variance on its type parameters the same way.
class Cell<out T> {
    constructor(readonly v: T) {}
}
const c1: Cell<unknown> = new Cell<string>("a");

// So does a generic type alias.
type Fn<in T, out R> = (x: T) => R;
declare const fn: Fn<string, string>;
const f1: Fn<string, unknown> = fn;
const f2: Fn<never, string> = fn;
