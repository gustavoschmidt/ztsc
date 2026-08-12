// A rest parameter typed by a UNION OF TUPLES has no per-position type, so
// tsc's `compareSignaturesRelated` stops the pairwise walk there and packs
// each side's remaining parameters into one tuple
// (`getNonArrayRestType` + `getRestTypeAtPosition`), relating the two packs
// contravariantly. The packed source below is `[event: string, string] |
// [event: string, number]`, and `any[]` is NOT assignable to that as a plain
// assignment (see `bare` at the bottom, which the oracle rejects) — yet the
// oracle accepts every signature pair whose TARGET packs to a bare `any[]`
// there. `assign.zig`'s `anyRestFrom` is that rule, and this case pins its
// boundary in both directions.

declare const q: (event: string, ...args: [number] | [string]) => void;

// ---- accepted: the target's pack at the rest position is a bare `any[]` ----
declare let a1: (...args: any[]) => any;
a1 = q;
declare let a2: (...args: any) => any;
a2 = q;
declare let a3: (...args: readonly any[]) => any;
a3 = q;
declare let a4: (...args: Array<any>) => any;
a4 = q;
declare let a5: (...args: [any, ...any[]]) => any;
a5 = q;
declare let a6: (...args: [...any[]]) => any;
a6 = q;
// The return type plays no part (so this is not tsc's `isAnySignature`, which
// also wants one parameter, no type parameters and an `any` return): the
// parameters relate here, and only the RETURN is reported.
declare let a7: (...args: any[]) => number;
a7 = q; // TS2322, on the return type alone
declare let a8: <T>(...args: any[]) => any;
a8 = q;
// A leading fixed target parameter is still related, normally and on its own.
declare let a9: (first: string, ...args: any[]) => any;
a9 = q;
declare const q2: (event: { a: number }, ...args: [number] | [string]) => void;
declare let a10: (...args: any[]) => any;
a10 = q2;
declare let a11: (first: string, ...args: any[]) => any;
a11 = q2; // TS2322: `string` is not assignable to `{ a: number }`
// The source may be longer than the target's whole list.
declare const q3: (a: string, b: string, ...args: [number] | [string]) => void;
declare let a12: (...args: any[]) => any;
a12 = q3;
declare let a13: (x: string, ...args: any[]) => any;
a13 = q3;

// ---- rejected: `any` is the whole rule ------------------------------------
declare let r1: (...args: unknown[]) => any;
r1 = q; // TS2322
declare let r2: (...args: number[]) => any;
r2 = q; // TS2322
declare let r3: (...args: (string | number)[]) => any;
r3 = q; // TS2322
declare let r4: (...args: [unknown, ...unknown[]]) => any;
r4 = q; // TS2322

// ---- rejected: the packed position is not the target's rest position ------
// The target's pack at position 0 is `[a: string, ...any[]]`, a tuple with a
// fixed head, and the oracle compares it in full.
declare const s: (...args: [string] | [number]) => void;
declare let r5: (a: string, ...args: any[]) => any;
r5 = s; // TS2322
declare const s2: (...args: [string, string] | [number, number]) => void;
declare let r6: (a: string, ...args: any[]) => any;
r6 = s2; // TS2322

// ---- the SOURCE side needs no rule: a tuple relates to `any[]` anyway -----
declare const t: (...args: any[]) => void;
declare let ok1: (event: string, ...args: [number] | [string]) => void;
ok1 = t;
declare const t2: (...args: unknown[]) => void;
ok1 = t2;

// ---- the plain assignment the signature rule is an exception to ----------
declare const bare: any[];
const packed: [event: string, string] | [event: string, number] = bare; // TS2322
const withHead: [a: string, ...any[]] = bare; // TS2322
