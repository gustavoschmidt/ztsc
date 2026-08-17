// TS2371: a parameter initializer needs a BODY to run it. Every signature-only
// position rejects one — and the rule reaches into the parameter's binding
// pattern, reporting on each element's TARGET rather than on the element's
// first token.

type FnType = (a: number = 1) => number;
type CtorType = new (a: number = 1) => object;

interface I {
    m(a: number = 1): void;
    new (a: number = 1): I;
    (a: number = 1): void;
}

declare function ambient(a: number = 1): void;

function overloaded(a: number = 1): void;
function overloaded(a?: number): void {}

class C {
    constructor(x: number = 1);
    constructor(x: number = 1) {}
    m(a: number = 1): void;
    m(a?: number) {}
}

declare class DC {
    m(a: number = 1): void;
}

abstract class AC {
    abstract am(a: number = 1): void;
}

// Inside a pattern: the shorthand element, an array element, a renamed element
// whose target is itself a pattern, and the parameter's own initializer beside
// one of its pattern's.
type Shorthand = ({ first = 0 }: { first?: number }) => void;
type Nested = ({ a: { b = 1 } }: any) => void;
type ArrayElem = ([p = 1]: any) => void;
type RenamedToPattern = ({ key: [y] = [1] }: any) => void;
type Both = ({ first = 0 } = {}) => void;

// A body makes every one of them legal.
function impl({ first = 0 }: { first?: number }, a = 1) {
    return first + a;
}
const arrow = ({ q = 2 }: { q?: number }, b = 3) => q + b;

export { overloaded, impl, arrow };
export type { FnType, CtorType, I, Shorthand, Nested, ArrayElem, RenamedToPattern, Both };
export { C, AC };
