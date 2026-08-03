// A generic interface reopened in several blocks pools its type-parameter
// DEFAULTS across all of them. tsc reads a default off the parameter's own
// symbol, whose declarations merge with the interface's, so a parameter is
// optional as soon as ANY block gives it one — declaration order does not
// matter.
//
// ztsc took the whole list from the first block that declared one, defaults
// included. `@types/node` writes the bare block first
// (`compatibility/iterators.d.ts` reopens
// `NodeJS.AsyncIterator<T, TReturn, TNext>`) and the defaulted one second
// (`globals.d.ts`: `<T, TReturn = undefined, TNext = any>`), so
// `NodeJS.AsyncIterator<any>` was a TS2314 arity error. That degrades to
// `any`, which is how `Readable`'s
// `[Symbol.asyncIterator](): NodeJS.AsyncIterator<any>` came back `any` and
// `for await (… of readable)` reported TS2504 — the receiver had no async
// iterator as far as the checker could tell.

interface Merged<T, U, V> {
  b: V;
}
interface Merged<T, U = number, V = boolean> {
  a: T;
  u: U;
}

declare const m: Merged<string>;
const mt: string = m.a;
const mu: number = m.u;
const mv: boolean = m.b;

// Same, inside a namespace, and with the defaulted block first.
declare namespace NS {
  interface Both<T, U = number> {
    a: T;
  }
  interface Both<T, U> {
    b: U;
  }
}
declare const b: NS.Both<string>;
const bt: string = b.a;
const bu: number = b.b;

// A default that names an EARLIER parameter still resolves against the block
// that wrote it.
interface Chain<A, B> {
  b: B;
}
interface Chain<A, B = A[]> {
  a: A;
}
declare const ch: Chain<number>;
const ca: number = ch.a;
const cb: number[] = ch.b;

// Arity still comes from the first declaring block: a bare reopen does not
// erase the parameters, and supplying every argument is unchanged.
declare const full: Merged<1, 2, 3>;
const fa: 1 = full.a;

export { mt, mu, mv, bt, bu, ca, cb, fa };
