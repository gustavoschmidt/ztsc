// A conditional type nested inside a TYPE ARGUMENT in the RETURN TYPE of a
// parenthesized function type — `(…) => Box<R extends X ? A : B>`.
//
// `(` starts a speculative parse (a parenthesized type is still a live
// alternative), and the speculation flag suppressed `parseType`'s claim on a
// trailing `extends`. That guard is right for the params but wrong past the
// `=>`, where the function type is already committed: the conditional was
// declined, the enclosing type-argument list then failed, and the whole
// function type backtracked into a parenthesized type — a parse error on valid
// code (rxjs's `bindCallback.d.ts`:
// `(...arg: A) => Observable<R extends [] ? void : R extends [any] ? R[0] : R>`).
//
// The non-speculative spellings (`new () =>`, `<T>() =>`, a call signature)
// always parsed; they are pinned here so the fix does not drift.
interface Box<T> {
  v: T;
}

type Peel<R extends readonly unknown[]> = () => Box<R extends [] ? void : R extends [any] ? R[0] : R>;

type WithParams<R> = (x: number) => Box<R extends string ? 'yes' : 'no'>;

type Nested<R> = () => () => Box<R extends string ? 1 : 2>;

type InObject<R> = { f: () => Box<R extends string ? 1 : 2> };

type Ctor<R> = new () => Box<R extends string ? 1 : 2>;

type Generic<R> = <T>() => Box<R extends string ? 1 : 2>;

interface CallSig<R> {
  (): Box<R extends string ? 1 : 2>;
}

// The parenthesized-type alternative must still backtrack correctly.
type Paren = number | string;
type ParenFn = (a: number) => void;
type Destructured = ({ a }: { a: number }) => void;

declare const peeled: Peel<[boolean]>;
const p0: boolean = peeled().v;
const p1: string = peeled().v; // TS2322

declare const empty: Peel<[]>;
const e0: void = empty().v;
const e1: number = empty().v; // TS2322

declare const wp: WithParams<string>;
const w0: 'yes' = wp(1).v;
const w1: 'no' = wp(1).v; // TS2322

declare const nst: Nested<number>;
const n0: 2 = nst()().v;
const n1: 1 = nst()().v; // TS2322

declare const io: InObject<string>;
const i0: 1 = io.f().v;
const i1: 2 = io.f().v; // TS2322

declare const ct: Ctor<string>;
const c0: 1 = new ct().v;
const c1: 2 = new ct().v; // TS2322

declare const gn: Generic<number>;
const g0: 2 = gn().v;
const g1: 1 = gn().v; // TS2322

declare const cs: CallSig<string>;
const s0: 1 = cs().v;
const s1: 2 = cs().v; // TS2322

declare const pr: Paren;
const r0: number | string = pr;
const r1: boolean = pr; // TS2322

declare const pf: ParenFn;
const f0: (a: number) => void = pf;
const f1: (a: string) => void = pf; // TS2322

declare const ds: Destructured;
const d0: ({ a }: { a: number }) => void = ds;
const d1: ({ a }: { a: string }) => void = ds; // TS2322
