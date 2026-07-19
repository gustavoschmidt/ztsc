// flatMap's `U | ReadonlyArray<U>` infers the element U, not the whole
// array (and no spurious `undefined` from ReadonlyArray's members).
interface Layer { k: string }
interface LR { layers: Layer[] }
declare const arr: LR[];
const flat = arr.flatMap((r) => r.layers);
const ok: Layer[] = flat;
declare function g<T>(x: T | ReadonlyArray<T>): T;
declare const ls: Layer[];
const one: Layer = g(ls);
const bad: string[] = flat; // TS2322
