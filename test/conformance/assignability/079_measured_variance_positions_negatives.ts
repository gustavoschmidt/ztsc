// The failing half of 079: every direction the measured variance forbids.

interface Out<T> {
    v: T;
    get(): T;
}
interface In<T> {
    set: (v: T) => void;
}
interface Inv<T> {
    get(): T;
    set: (v: T) => void;
}

declare const ou: Out<unknown>;
const a: Out<string> = ou; // covariant, wrong way

declare const is: In<string>;
const b: In<unknown> = is; // contravariant, wrong way

declare const vs: Inv<string>;
const c: Inv<unknown> = vs; // invariant
const d: Inv<never> = vs; // invariant, the other way

const e: Out<Out<string>> = {} as Out<Out<unknown>>; // nested covariant
const f: Out<In<unknown>> = {} as Out<In<string>>; // nested contravariant

declare class Fluent<T> {
    v: T;
    self(): this;
    same(other: this): boolean;
    boxed(): Out<this>;
}
declare const fu: Fluent<unknown>;
const g: Fluent<string> = fu;

interface Node2<T> {
    value: T;
    next: Node2<T> | undefined;
}
const h: Node2<string> = {} as Node2<unknown>;

interface Pair<A, B> {
    a: A;
    put: (b: B) => void;
}
const i: Pair<string, unknown> = {} as Pair<unknown, string>;
