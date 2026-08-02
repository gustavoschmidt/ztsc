// The other half of 078: measuring a generic's variance must not turn the
// relation into "any two instantiations of the same generic are related".
// Every pair below still has to fail, on the type ARGUMENTS.

interface Def {
    d?: string;
}
type Any = Base<any, any, any>;

declare abstract class Base<Output = any, D extends Def = Def, Input = Output> {
    readonly _output: Output;
    readonly _input: Input;
    readonly _def: D;
    optional(): Opt<this>;
    describe(d: string): this;
    accepts(other: this): boolean;
}

interface OptDef<T extends Any> extends Def {
    inner: T;
}

declare class Opt<T extends Any> extends Base<T["_output"] | undefined, OptDef<T>, T["_input"] | undefined> {
    unwrap(): T;
}

declare class Num extends Base<number, Def, number> {
    min(v: number): this;
}
declare class Str extends Base<string, Def, string> {
    max(v: number): this;
}

// Same wrapper, unrelated arguments.
declare const on: Opt<Num>;
const a: Opt<Str> = on;

// The base itself is measured too: `Output` is covariant, so `number` does
// not reach `string`.
declare const n: Num;
const b: Base<string, Def, string> = n;

// A parameter used in BOTH positions is invariant: neither widening nor
// narrowing the argument relates.
interface Cell<T> {
    get(): T;
    set: (v: T) => void;
}
declare const cs: Cell<string>;
const c: Cell<unknown> = cs;
const d: Cell<never> = cs;

// A parameter used only in a contravariant position goes the other way.
interface Sink<T> {
    take: (v: T) => void;
}
declare const ks: Sink<string>;
const e: Sink<unknown> = ks;

// A covariant parameter still rejects the widening direction reversed.
interface Src<T> {
    get(): T;
}
declare const gu: Src<unknown>;
const f: Src<string> = gu;
