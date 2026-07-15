// Member-expression computed keys `[a.b]`: a class-static or
// namespace-exported `unique symbol` used as a property key (node's
// `[EventEmitter.captureRejectionSymbol]`, util's `[promisify.custom]`).
declare class Emitter {
  static readonly captureRejection: unique symbol;
  [Emitter.captureRejection]?(error: Error): void;
}
declare const e: Emitter;
const h = e[Emitter.captureRejection];
const hbad: number = e[Emitter.captureRejection]; // method|undefined -> number

// Namespace-exported symbol on a function+namespace merge.
declare function promisify(fn: Function): Function;
declare namespace promisify {
  const custom: unique symbol;
}
interface P {
  [promisify.custom]: string;
}
declare const p: P;
const pc: string = p[promisify.custom];
const pbad: boolean = p[promisify.custom]; // string -> boolean

// The key participates in structural checks like a named property.
const miss: P = {}; // missing '[promisify.custom]'

// A non-well-known `Symbol` member declared as plain `symbol` (rxjs's
// `[Symbol.observable]`): declarable, keyed by name (lenient corner).
interface SymbolConstructor {
  readonly observable: symbol;
}
interface Interop {
  [Symbol.observable]: () => number;
}

// Self-referential static key: `Cyclic.kk` named from inside `Cyclic`'s own
// static side — must resolve without a cycle (lenient placeholder is fine).
declare class Cyclic {
  static readonly kk: unique symbol;
  static readonly [Cyclic.kk]: string;
}
