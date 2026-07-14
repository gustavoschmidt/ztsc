// +/- add/remove modifiers.
type Mutable<T> = { -readonly [K in keyof T]: T[K] };
type DeepRequired<T> = { [K in keyof T]-?: T[K] };
type AllReadonlyOpt<T> = { +readonly [K in keyof T]+?: T[K] };

interface Locked { readonly a: number; readonly b: string; }
declare const m: Mutable<Locked>;
m.a = 10; // ok now (readonly stripped) -> no error
const ma: number = m.a;

interface Mixed { a: number; b?: string; }
declare const ar: AllReadonlyOpt<Mixed>;
ar.a = 1; // TS2540 (+readonly added)
const arb: string | undefined = ar.b;
