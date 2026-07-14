// A homomorphic identity map preserves the source's readonly/optional
// modifiers per property (no modifier of its own).
interface Src { readonly a: number; b?: string; c: boolean; }
type Id<T> = { [K in keyof T]: T[K] };

declare const s: Id<Src>;
s.a = 1;                    // TS2540 (readonly preserved)
const sb: string = s.b;     // TS2322 (optional preserved -> string | undefined)
const sc: boolean = s.c;    // ok
