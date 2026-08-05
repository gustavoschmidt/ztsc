// Two rules `getIntersectionType` applies to primitives, both missing.
//
// 1. DISJOINT DOMAINS. tsc: *"an intersection is empty if it contains a
//    string-like type and a type known to be non-string-like, a number-like
//    type and a type known to be non-number-like, …"* — `TypeFlags.
//    DisjointDomains` is `NonPrimitive | StringLike | NumberLike | BigIntLike |
//    ESSymbolLike | VoidLike | Null`. `boolean` and `TypeFlags.Object` are
//    deliberately NOT in it, which is what keeps a branded `string & {brand}`
//    and `NonNullable<T>`'s `T & {}` alive.
//
// 2. REDUNDANT PRIMITIVES (`removeRedundantPrimitiveTypes`). A base primitive
//    is dropped when a literal of the same primitive is present, so
//    `"a" & string` IS `"a"`.
//
// Together they are what makes the `keyof M & (string | symbol)` key-filter
// idiom work: without (1) the `"a" & symbol` products survive, without (2) the
// `"a" & string` ones do, and `M[keyof M & (string | symbol)]` then indexes
// nothing. socket.io's `EventNames` is written exactly that way, and the whole
// `IsAny<T> = 0 extends 1 & T ? true : false` family needs (1) as well.

// --- (1) disjoint domains
declare const a1: 1 & string;
declare const a2: 1 & symbol;
declare const a3: string & number;
declare const a4: undefined & string;
declare const a5: null & undefined;
declare const a6: object & string;
export const n1: never = a1;
export const n2: never = a2;
export const n3: never = a3;
export const n4: never = a4;
export const n5: never = a5;
export const n6: never = a6;

// NOT disjoint: an object type is not `NonPrimitive`, and `boolean` is not a
// domain at all.
declare const b1: string & { brand: 1 };
export const k1: string = b1;
declare const b2: string & {};
export const k2: string = b2;
declare const b3: true & string;
export const k3: unknown = b3;

// --- (2) redundant primitives
declare const c1: 'a' & string;
export const k4: 'a' = c1;
export const k5: 'b' = c1;
declare const c2: 1 & number;
export const k6: 1 = c2;
declare const c3: symbol & typeof uniq;
declare const uniq: unique symbol;
export const k7: typeof uniq = c3;
declare const c4: void & undefined;
export const k8: undefined = c4;

// The key-filter idiom, which needs both.
type M = { a: (x: number) => void; b: (y: string) => void };
type Keys = keyof M & (string | symbol);
declare const k: Keys;
export const k9: 'a' | 'b' = k;
export const k10: 'a' = k;
declare const v: M[Keys];
export const k11: ((x: number) => void) | ((y: string) => void) = v;

type IsAny<T> = 0 extends 1 & T ? true : false;
export const k12: false = null as any as IsAny<M[Keys]>;
export const k13: true = null as any as IsAny<any>;
