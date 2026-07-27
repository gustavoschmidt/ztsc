// `typeof globalThis` is the global-scope object — NOT `any`. Its members are
// the program's global VALUE declarations, resolved on demand (the set is
// lib-sized and self-referential, so it is never materialized eagerly).
import './decl';

const a: string = globalThis.appName;
const b: number = globalThis.appName; // TS2322
const c: string = globalThis.greet('x');
const d: number = globalThis.greet('x'); // TS2322
const e: number = globalThis.appNs.count;

// A block-scoped global is in lexical scope but is NOT a property of the
// global object.
const f: number = appVersion;
const g = globalThis.appVersion; // TS2339
const h = globalThis.AppClass; // TS2339

// A name with no global VALUE meaning at all is an implicit-any index, not a
// missing property.
const i = globalThis.AppShape; // TS7017

// `typeof globalThis` itself is a real type, not `any`.
declare const j: typeof globalThis;
const k: number = j; // TS2322

// `X & typeof globalThis` resolves BOTH halves — the interface's own members
// and the global scope's.
const l: number = appHost.n;
const m: string = appHost.appName;
const n: number = appHost.n2; // TS2339
