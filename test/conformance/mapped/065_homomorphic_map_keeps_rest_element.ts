// A homomorphic mapped type over a TUPLE must keep a rest element's element
// type WRAPPED in its array (tsc's `instantiateMappedTupleType` maps the
// element type and re-attaches the rest flag to an array-shaped slot).
//
// ztsc stores a rest slot's ARRAY type (`...string[]` holds `string[]`) and
// every reader unwraps it with `elemOfArrayish`. The map's value template is
// `T[i]`, which for a rest slot already hands back the ELEMENT type, so
// writing that straight back produced `readonly [string, ...string]` — a rest
// slot holding a non-array. The next reader unwrapped it again and got
// nothing, so a contextual type taken from such a tuple was lost for every
// position past the fixed prefix.
//
// zod's `z.enum(['a','b','c'])` is the shape: `create` constrains its tuple by
// `Readonly<[U, ...U[]]>`, so `U` is the contextual type for each element. With
// the rest slot broken only element 0 kept its literal type and the rest
// widened to `string`, so `z.infer` on the schema said `string` where the
// schema says `'a' | 'b' | 'c'`.
type Ro<T> = { readonly [P in keyof T]: T[P] };

type RestOfStrings = Ro<[string, ...string[]]>;
declare const r: RestOfStrings;
// A rest slot accepts any number of trailing elements, so every position past
// the prefix reads as the element type — and a fixed-length target still needs
// its own arity (the negative below).
export const r0: readonly string[] = r;
export const r1: string = r[7];
export const r2: readonly [string, string, string] = r;

// The map runs over the ELEMENT type, so a wrapping template applies to it.
type Boxed<T> = { readonly [P in keyof T]: { v: T[P] } };
type BoxedRest = Boxed<[number, ...string[]]>;
declare const b: BoxedRest;
export const b0: { v: number } = b[0];
export const b1: { v: string } = b[3];

// The contextual type for every element past the prefix is the rest element's
// type, so a literal argument keeps its literal type there too.
declare function pick<U extends string, T extends Ro<[U, ...U[]]>>(values: T): T;
export const picked: readonly ['a', 'b', 'c'] = pick(['a', 'b', 'c']);

// A fixed-length tuple is unaffected, and so is an array source.
type Fixed = Ro<[number, string]>;
declare const f: Fixed;
export const f0: number = f[0];
export const f1: string = f[1];
type Arr = Ro<string[]>;
declare const a: Arr;
export const a0: string = a[0];

// Negative: the rest slot really is a rest slot, not a single element.
export const bad: string = r;
