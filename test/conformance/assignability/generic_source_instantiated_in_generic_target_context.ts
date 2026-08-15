// tsc's `compareSignaturesRelated` replaces a generic SOURCE signature with
// `instantiateSignatureInContextOf(source, target)` and compares THAT — with
// the target's own type parameters left FREE, and with no fallback to an
// erasure once the instantiation exists. Every line below is oracle-verified
// against tsgo 7.0.2.

// ---------------------------------------------------------------- rejections
// The target's type parameters stay free, so a source that only works for
// SOME instantiation of them does not relate. Erasing both sides to their
// constraints instead collapsed `T_A` and `T_I` to `any` and accepted all of
// these.

interface A {
    a4: new <T, U>(x: T, y: U) => string;
    a5: new <T, U>(x: (arg: T) => U) => T;
}

interface I4<T> extends A {
    a4: new <U>(x: T, y: U) => string; // TS2430: `I4`'s `T` is not `A`'s
}

interface I5<T> extends A {
    a5: new <U>(x: (arg: T) => U) => T; // TS2430: likewise
}

// A generic source against a NON-generic target: the erasure sent the return
// to `any`, which satisfies every target return.
interface B {
    a15: (x: { a: string; b: number }) => number;
}
interface I6 extends B {
    a15: <T>(x: { a: T; b: T }) => T; // TS2430
}

// Both sides generic, one returning the parameter and one a fixed type.
interface C {
    a2: <T>(x: T) => T[];
}
interface I7 extends C {
    a2: <T>(x: T) => string[]; // TS2430
}

// ---------------------------------------------------------------- acceptances
// The instantiation has to actually be computed, or these become false
// positives once the arm above starts reporting.

// A parameter with no candidate falls back to its CONSTRAINT (`V := Derived2`),
// which is what `getInferredType` does when inference found nothing.
class Base {
    foo!: string;
}
class Derived extends Base {
    bar!: string;
}
class Derived2 extends Derived {
    baz!: string;
}
interface D {
    a7: (x: (arg: Base) => Derived) => (r: Base) => Derived2;
}
interface I8 extends D {
    a7: <T extends Base, U extends Derived, V extends Derived2>(x: (arg: T) => U) => (r: T) => V; // ok
}

// A contextual signature whose rest parameter supplies every POSITION: the
// pairing is positional, so `A := string` and `B := string` rather than
// `A := string[]`.
declare function toInstantiate<X, Y>(a?: X, b?: Y): Y;
declare function contextual(...s: string[]): string;
const sig: typeof contextual = toInstantiate; // ok

// A generic method reached through an instantiation of its own class: ztsc
// keys a type parameter by its declaration symbol and does not clone, so
// `Cons<U>` written inside `Cons.map<U>` CAPTURES the method's `U`. The
// inference declines rather than solving `U := D` and rejecting the pair.
interface IList<E> {
    map<F>(f: (t: E) => F): IList<F>;
}
class Nil<G> implements IList<G> {
    map<H>(f: (t: G) => H): IList<H> {
        return null as any;
    }
}
class Cons<T> implements IList<T> {
    map<U>(f: (t: T) => U): IList<U> {
        return this.foldRight(new Nil<U>(), (t, acc) => new Cons<U>()); // ok
    }
    foldRight<E2>(z: E2, f: (t: T, acc: E2) => E2): E2 {
        return null as any;
    }
}

// A candidate that fails its constraint declines too, so the pair falls to the
// erase-to-constraints path — which tsgo agrees with here (both sides erase to
// a `string`-returning signature).
declare const s1: <T extends string>() => T;
const q1: <T extends string>() => T | Promise<T> = s1; // ok
