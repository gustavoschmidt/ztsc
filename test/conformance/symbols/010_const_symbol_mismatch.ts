// Accessing a symbol-keyed member with a DIFFERENT unique symbol must not
// resolve (TS7053), and a non-`unique` symbol key degrades leniently.
declare const k: unique symbol;
declare const other: unique symbol;

class C {
  static readonly [k]: string;
}
const ok: string = C[k];
const no = C[other]; // TS7053: 'other' can't index typeof C

interface I {
  readonly [k]: string;
}
declare const i: I;
const noi = i[other]; // TS7053

// A plain (non-`unique`) symbol key: allowed, but keyed leniently by name.
declare const s: symbol;
interface J {
  [s]: string;
}
