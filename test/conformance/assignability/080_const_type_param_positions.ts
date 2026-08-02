// `const` is a type-parameter modifier only where there is a CALL SITE to
// infer from — a function, a method, or a class (through its constructor).
// An interface or a type alias declares no call site of its own, so `const`
// there is TS1277. The sibling rule for `in`/`out` (TS1274) is
// assignability/076; the two overlap only on a class, which admits both.

// --- valid ------------------------------------------------------------
declare function fn<const T>(x: T): T;

const arrow = <const T,>(x: T): T => x;

class Cls<const T> {
    constructor(readonly v: T) {}
    m<const U>(x: U): U {
        return x;
    }
}

interface HasMethods {
    m<const T>(x: T): T;
    <const T>(x: T): T;
    new <const T>(x: T): T;
}

type FnType = <const T>(x: T) => T;
type CtorType = new <const T>(x: T) => T;
type ObjType = { m<const T>(x: T): T };

// A class may carry `const` and a variance annotation on the same parameter.
class Both<const in out T> {
    v!: T;
}

// --- invalid ----------------------------------------------------------
interface Iface<const T> {
    v: T;
}

type Alias<const T> = { v: T };

// tsc reports the FIRST offending modifier of a parameter and stops, so a
// function's `<const in out T>` is one TS1274 (at `in`), not two.
declare function combo<const in out T>(x: T): T;
