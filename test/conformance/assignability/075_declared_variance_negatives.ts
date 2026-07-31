// The other half of 075: an annotation that does NOT hold rejects the pair,
// including pairs whose members would have matched bivariantly.

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

declare const gu: Getter<unknown>;
const g1: Getter<string> = gu; // covariant: unknown -> string fails

declare const ss: Setter<string>;
const s1: Setter<unknown> = ss; // contravariant: unknown -> string fails

declare const bs: Both<string>;
const b1: Both<unknown> = bs; // invariant: one direction is enough to fail
const b2: Both<string> = {} as Both<unknown>;

// A method parameter is bivariant structurally — `in` is what rejects this.
interface MethodParam<in T> {
    m(v: T): void;
}
const mp: MethodParam<unknown> = {} as MethodParam<string>;

interface Wrap<out T> {
    v: T;
}
const w1: Wrap<Getter<string>> = {} as Wrap<Getter<unknown>>;

class Cell<out T> {
    constructor(readonly v: T) {}
}
const c1: Cell<string> = new Cell<unknown>(1);

type Fn<in T, out R> = (x: T) => R;
const f1: Fn<string, string> = {} as Fn<unknown, unknown>;
