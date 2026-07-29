// Element access whose KEY expression is a union of literals distributes:
// `o[k]` with `k: "a" | "b"` is `o["a"] | o["b"]`. The type-level form
// (`Obj["a" | "b"]`) is 002; this is the expression form, which used to fall
// through to an implicit `any` and take the contextual signature of anything
// the read fed with it.
type Dir = "n" | "s" | "e" | "w";
declare const d: Dir;

declare const rec: Record<Dir, [x: boolean, y: boolean]>;
const pair = rec[d];
const pbad: string = pair;                    // TS2322 (tuple -> string)
const [px] = rec[d].map((condition) => condition);
const pxbad: string = px;                     // TS2322 (boolean -> string)

declare const mixed: { n: number; s: string; e: number; w: number };
const m1: number | string = mixed[d];
const mbad: boolean = mixed[d];               // TS2322 (string | number -> boolean)

declare const arrs: Record<Dir, boolean[]>;
const abad: string = arrs[d].map((c) => c);   // TS2322 (boolean[] -> string)

// A number-literal key union indexes a tuple element-wise.
declare const tup: [string, number, boolean];
declare const i01: 0 | 1;
const tbad: boolean = tup[i01];               // TS2322 (string | number -> boolean)

// An optional member contributes `| undefined`, as it does for a single key.
declare const opt: { n?: number; s: number; e: number; w: number };
const obad: number = opt[d];                  // TS2322 (number | undefined -> number)

// A string index signature covers the keys the property list misses.
declare const sig: { n: number } & { [k: string]: number };
const sbad: string = sig[d];                  // TS2322 (number -> string)

// Distribution over a union RECEIVER still works with a union key.
declare const recv: { n: number; s: number } | { n: string; s: string };
declare const ns: "n" | "s";
const rbad: boolean = recv[ns];               // TS2322 (string | number -> boolean)
