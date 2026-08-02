// The sibling of 078: the same recursive `this`-typed family, but related
// against a base instantiation whose arguments are NOT `any`.
//
// zod's `ZodRecord<Key extends KeySchema>` writes its constraint as
// `ZodType<string | number | symbol, any, any>`, and the argument is a
// subclass INSTANCE (`ZodString`), not a reference. No fast path applies:
// the source is not the target's origin ref, and the two symbols differ, so
// neither the reflexive-origin shortcut nor the variance verdict decides it,
// and the structural walk runs.
//
// That walk does not repeat. Every member hands its own `this` to another
// wrapper, so the pair one level down is a STRICTLY LARGER instantiation of
// the same handful of generics (`Base<string, …>` → `Isec<Base<string, …>,
// Any>` → `Base<any, IsecDef<…>, any>` → `Arr<…>` → …), a dozen ways per
// level. Nothing ever repeats, so neither the relation memo nor the
// expansion memo closes it: the walk used to run until the per-statement
// instantiation budget tripped, and the truncation to `error_type` came back
// as a FALSE relation — cached, and then reused, which is where `ZodString`
// stopped satisfying `ZodType<string | number | symbol, any, any>`.
// Recognising the repeated GENERIC rather than the repeated instantiation
// (`max_relation_identity_repeats`) closes it in three levels.

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
    promise(): Prom<this>;
    or<T extends Any>(option: T): Uni<[this, T]>;
    and<T extends Any>(incoming: T): Isec<this, T>;
    pipe<T extends Any>(target: T): Pipe<this, T>;
    def(v: Output): Dflt<this>;
    fallback(v: Output): Ctch<this>;
    readonly(): Ro<this>;
    describe(d: string): this;
}

interface OptDef<T extends Any> extends Def {
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

declare class Opt<T extends Any> extends Base<T["_output"] | undefined, OptDef<T>, T["_input"] | undefined> {
    unwrap(): T;
}
declare class Nul<T extends Any> extends Base<T["_output"] | null, OptDef<T>, T["_input"] | null> {
    unwrap(): T;
}
declare class Arr<T extends Any> extends Base<T["_output"][], ArrDef<T>, T["_input"][]> {
    element: T;
}
declare class Prom<T extends Any> extends Base<T["_output"], OptDef<T>, T["_input"]> {
    unwrap(): T;
}
declare class Uni<T extends readonly [Any, ...Any[]]> extends Base<T[number]["_output"], UniDef<T>, T[number]["_input"]> {
    options(): T;
}
declare class Isec<T extends Any, U extends Any> extends Base<T["_output"] & U["_output"], IsecDef<T, U>, T["_input"] & U["_input"]> {
    left(): T;
}
declare class Pipe<A extends Any, B extends Any> extends Base<B["_output"], IsecDef<A, B>, A["_input"]> {
    first(): A;
}
declare class Dflt<T extends Any> extends Base<T["_output"], OptDef<T>, T["_input"] | undefined> {
    removeDefault(): T;
}
declare class Ctch<T extends Any> extends Base<T["_output"], OptDef<T>, unknown> {
    removeCatch(): T;
}
declare class Ro<T extends Any> extends Base<T["_output"], OptDef<T>, T["_input"]> {
    unwrap(): T;
}

declare class Str extends Base<string, Def, string> {
    max(v: number): this;
}
declare class Num extends Base<number, Def, number> {
    gt(v: number): this;
}

// The shape the constraint is written as: a base instantiation whose first
// argument is a key union and whose others are `any`.
type KeySchema = Base<string | number | symbol, any, any>;

declare const s: Str;
declare const n: Num;

// Direct assignment: a subclass instance to the non-`any` base instantiation.
const a: KeySchema = s;
const b: Base<string | number | symbol, any, any> = n;

// The same relation reached as a TYPE-ARGUMENT constraint, which is where
// zod's `ZodRecord<ZodString, Value>` hits it.
declare class Rec<K extends KeySchema, V extends Any> extends Base<Def, Def, Def> {
    keySchema: K;
    valueSchema: V;
    static make<V2 extends Any>(v: V2): Rec<Str, V2>;
    static makeWith<K2 extends KeySchema, V2 extends Any>(k: K2, v: V2): Rec<K2, V2>;
}
type R1 = Rec<Str, Num>;
type R2 = Rec<Num, Str>;

// And through a wrapper, whose own `this` chain is what used to grow.
declare const os: Opt<Str>;
const c: Base<string | undefined, any, any> = os;
type R3 = Rec<Opt<Str>, Num>;

export { a, b, c };
export type { R1, R2, R3 };
