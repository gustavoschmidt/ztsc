// Computed property keys named by a const `unique symbol` — declarable in
// classes (static), interfaces, type literals and object literals, keyed by
// the symbol's nominal identity.
declare const k: unique symbol;

class C {
  static readonly [k]: string;
}
const cs: string = C[k];
const cbad: number = C[k]; // string -> number

interface I {
  readonly [k]: string;
  n: number;
}
declare const i: I;
const is_: string = i[k];
const ibad: boolean = i[k]; // string -> boolean

type T = { readonly [k]: number };
declare const t: T;
const ts_: number = t[k];

const o = { [k]: 42 };
const os_: number = o[k];
const obad: string = o[k]; // number -> string

// The key participates in structural checks like a named property.
const miss: I = { n: 1 }; // missing '[k]'
