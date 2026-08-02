// Variance MEASURED from the structure (tsc's `getVariances`), not declared.
//
// The zod shape: a generic base class whose members hand their own
// polymorphic `this` to other generics, each of which extends the base again
// through indexed accesses on its parameter. Relating a subclass to
// `Base<any, any, any>` compares `Opt<Sub>` against `Opt<Base<any,any,any>>`
// at every member, and expanding those bodies structurally re-enters the
// whole base member set one wrapper deeper — an unbounded, exponentially
// branching walk. Measured variance decides each wrapper pair by its type
// ARGUMENTS instead, and the argument pair is the very relation already in
// flight.

interface Def {
    d?: string;
}
type Any = Base<any, any, any>;

declare abstract class Base<Output = any, D extends Def = Def, Input = Output> {
    readonly _output: Output;
    readonly _input: Input;
    readonly _def: D;
    optional(): Opt<this>;
    nullable(): Nul<this>;
    array(): Arr<this>;
    or<T extends Any>(option: T): Uni<[this, T]>;
    and<T extends Any>(incoming: T): Isec<this, T>;
    pipe<T extends Any>(target: T): Pipe<this, T>;
    readonly(): Ro<this>;
    describe(d: string): this;
    accepts(other: this): boolean;
}

interface OptDef<T extends Any> extends Def {
    inner: T;
}
interface NulDef<T extends Any> extends Def {
    inner: T;
}
interface ArrDef<T extends Any> extends Def {
    inner: T;
}
interface UniDef<T extends readonly [Any, ...Any[]]> extends Def {
    opts: T;
}
interface IsecDef<T extends Any, U extends Any> extends Def {
    l: T;
    r: U;
}
interface PipeDef<A extends Any, B extends Any> extends Def {
    a: A;
    b: B;
}
interface RoDef<T extends Any> extends Def {
    inner: T;
}

declare class Opt<T extends Any> extends Base<T["_output"] | undefined, OptDef<T>, T["_input"] | undefined> {
    unwrap(): T;
}
declare class Nul<T extends Any> extends Base<T["_output"] | null, NulDef<T>, T["_input"] | null> {
    unwrap(): T;
}
declare class Arr<T extends Any> extends Base<T["_output"][], ArrDef<T>, T["_input"][]> {
    element: T;
}
declare class Uni<T extends readonly [Any, ...Any[]]> extends Base<T[number]["_output"], UniDef<T>, T[number]["_input"]> {
    options(): T;
}
declare class Isec<T extends Any, U extends Any> extends Base<T["_output"] & U["_output"], IsecDef<T, U>, T["_input"] & U["_input"]> {
    left(): T;
}
declare class Pipe<A extends Any, B extends Any> extends Base<B["_output"], PipeDef<A, B>, A["_input"]> {
    first(): A;
}
declare class Ro<T extends Any> extends Base<T["_output"], RoDef<T>, T["_input"]> {
    unwrap(): T;
}

declare class Num extends Base<number, Def, number> {
    min(v: number): this;
}
declare class Str extends Base<string, Def, string> {
    max(v: number): this;
}

// The headline case: a concrete subclass IS a `Base<any, any, any>`.
declare const n: Num;
const a: Base<any, any, any> = n;
const b: Any = n;

declare const s: Str;
const c: Base<any, any, any> = s;

// Through the wrappers, both ways round.
declare const on: Opt<Num>;
const d: Base<any, any, any> = on;
const e: Opt<Any> = on;
declare const rn: Ro<Arr<Num>>;
const f: Any = rn;

// A type-argument position with a structural constraint: the constraint
// check is the same relation.
type Wrapped<T extends Base<any, any, any>> = Opt<T>;
type W1 = Wrapped<Num>;
type W2 = Wrapped<Opt<Str>>;

// A generic function whose parameter carries the same constraint.
declare function unwrapAll<T extends Base<any, any, any>>(x: T): T;
const g = unwrapAll(n);
const h = unwrapAll(on);
