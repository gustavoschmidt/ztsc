export {};

// tsc's empty-intersection rule: `null` / `undefined` intersected with a type
// from any other domain has no inhabitants and reduces to `never`.

type A = null & {};
type B = undefined & {};
type C = null & { a: 1 };
type D = undefined & string;
type E = null & number;
type F = null & (() => void);
type G = null & number[];
type H = null & undefined;
type I = null & object;

declare const a: A;
declare const b: B;
declare const c: C;
declare const d: D;
declare const e: E;
declare const f: F;
declare const g: G;
declare const h: H;
declare const i: I;

// `never` is assignable to everything: none of these is an error.
const ra: number = a;
const rb: number = b;
const rc: number = c;
const rd: number = d;
const re: number = e;
const rf: number = f;
const rg: number = g;
const rh: number = h;
const ri: number = i;

// NEGATIVE: `void` is a domain of its own — `void & {}` is NOT empty, and a
// nullish intersection with nothing else stays nullish.
type J = void & {};
type K = void & { a: 1 };
type L = null & unknown;
type M = undefined & undefined;
declare const j: J;
declare const k: K;
declare const l: L;
declare const m: M;
const rj: number = j;
const rk: number = k;
const rl: number = l;
const rm: number = m;

// NEGATIVE: a type parameter is not a known domain, so `T & {}`
// (`NonNullable`) must stay deferred and keep rejecting a bad assignment.
function nn<T>(x: T & {}): number {
  return x;
}

// The motivating shape: `NonNullable` over a branded string union.
type FileId = string & { _brand: "FileId" };
type NN<T> = T & {};
declare const v: NN<FileId | null>;
declare function takesFileId(x: FileId): void;
takesFileId(v);
