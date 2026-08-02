// Where the measurement reads a type parameter from, one position at a time:
// covariant (return / property), contravariant (function-property
// parameter), bivariant (method parameter), invariant (both), and
// independent (never witnessed). Each generic is UNANNOTATED — the verdict
// has to come from the structure.

interface Out<T> {
    v: T;
    get(): T;
}
interface In<T> {
    set: (v: T) => void;
}
interface Bi<T> {
    m(v: T): void;
}
interface Inv<T> {
    get(): T;
    set: (v: T) => void;
}
interface Free<T> {
    n: number;
}

declare const os: Out<string>;
const a: Out<unknown> = os; // covariant

declare const iu: In<unknown>;
const b: In<string> = iu; // contravariant

declare const bs: Bi<string>;
const c: Bi<unknown> = bs; // bivariant: the method parameter relates either way
const d: Bi<string> = {} as Bi<unknown>;

declare const vs: Inv<string>;
const e: Inv<string> = vs; // invariant: identical arguments only

const f: Free<string> = {} as Free<number>; // independent: the argument is not witnessed

// The parameter flowing through ANOTHER generic reference keeps its
// direction: `Out<Out<T>>` is covariant in T, `Out<In<T>>` contravariant.
const g: Out<Out<unknown>> = {} as Out<Out<string>>;
const h: Out<In<string>> = {} as Out<In<unknown>>;

// Polymorphic `this` in a RETURN position is covariant; in a method
// PARAMETER position it stays bivariant, so a wrapper over `this` relates
// both ways for the sub/super pair.
declare class Fluent<T> {
    v: T;
    self(): this;
    same(other: this): boolean;
    boxed(): Out<this>;
}
declare const fs: Fluent<string>;
const i: Fluent<unknown> = fs;

// A recursive generic: the parameter is witnessed only through an
// instantiation of the generic itself, which the measurement must not chase
// forever.
interface Node2<T> {
    value: T;
    next: Node2<T> | undefined;
}
const j: Node2<unknown> = {} as Node2<string>;

// Two parameters, measured independently.
interface Pair<A, B> {
    a: A;
    put: (b: B) => void;
}
const k: Pair<unknown, string> = {} as Pair<string, unknown>;
