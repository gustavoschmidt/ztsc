// Eagerly driving a recursive alias must not run one hop too far, and must
// leave alone the aliases the lazy spelling exists for.
declare const arr: (string | { id: string }[] | { id: string })[];

// `flat()` flattens exactly one level.
declare const deep: string[][][];
export const one: string[][] = deep.flat();

// Depth 0 is the identity — the nested array constituent survives.
type A = typeof arr;
declare const e: FlatArray<A, 0>;
export const bad: string | { id: string } = e;

// A recursive alias whose body is an OBJECT keeps its single ref spelling; it
// is reached here through a generic call's return type.
type List<T> = { head: T; tail: List<T> | null };
declare function wrap<T>(v: T): List<T>;
export const w: string = wrap(1).head;
export const w2: List<string> = wrap(1);

// A recursive alias reached through a conditional whose check is NOT decidable
// from its shape alone stays deferred: the reduction must not be forced.
type Peel<T> = T extends [infer H, ...infer R] ? Peel<R> : T;
declare function peel<T extends unknown[]>(t: T): Peel<T>;
export const p1: [] = peel([1, "a"] as [number, string]);
export const p2 = <T extends unknown[]>(t: T): Peel<T> => peel(t);
