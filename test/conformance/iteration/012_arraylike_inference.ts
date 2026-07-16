// Type-arg inference from array/tuple/string args against object-shaped
// params (`ArrayLike<T>`, `Iterable<T>`): the number index matches the
// element type, props resolve via the primitive interfaces.
interface Thing {
  id: number;
}
declare const things: Thing[];
const copy = Array.from(things);
const bad: number[] = copy; // Thing[] -> number[]

const chars = Array.from("abc");
const cbad: number[] = chars; // string[] -> number[]

declare function firstOf<T>(xs: ArrayLike<T>): T;
const f = firstOf(things);
const fbad: string = f; // Thing -> string

declare function fromPair<T>(xs: Iterable<T> | ArrayLike<T>): T[];
const p = fromPair([1, "a"] as const);
const pbad: boolean[] = p; // (1 | "a")[] -> boolean[]
