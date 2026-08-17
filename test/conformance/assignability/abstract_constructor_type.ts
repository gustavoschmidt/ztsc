// tsc's `signaturesRelatedTo`, construct half: an ABSTRACT constructor type is
// not assignable to a non-abstract one, or the target could `new` a class with
// unimplemented members. The reverse stays legal.

abstract class Abs {
    abstract m(): number;
}
class Conc {
    m(): number {
        return 1;
    }
}
abstract class AbsSub extends Conc {
    static tag = "s";
}

declare let concCtor: typeof Conc;
declare let absCtor: typeof Abs;
declare let absSubCtor: typeof AbsSub;

// class value -> class value
export const a: typeof Conc = concCtor;
export const b: typeof Abs = concCtor; // fine: concrete satisfies abstract
export const c: typeof Conc = absSubCtor; // error

// class value -> an interface carrying a construct signature
interface Factory {
    new (): Conc;
    tag: string;
}
declare let f: Factory;
export const d: Factory = f;
export const e: Factory = absSubCtor; // error

// A parameter position takes the same rule.
declare function make(k: typeof Conc): Conc;
export const g = make(concCtor);
export const h = make(absSubCtor); // error

// `abstract new (…) => T` accepts an abstract class value — the rule is
// one-sided, and ztsc must not reject this one.
declare function forAbstract<T>(k: abstract new (...args: any[]) => T): T;
export const i: number = forAbstract(Abs).m();
