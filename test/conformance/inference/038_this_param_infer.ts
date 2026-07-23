// A type parameter that appears only in an explicit `this` parameter is
// inferred from the call's receiver (tsc treats the receiver as the `this`
// argument). Without it the param stays unbound — e.g. `Array.prototype.flat`
// (`flat<A, D extends number = 1>(this: A, depth?: D): FlatArray<A, D>[]`)
// returns `unknown[]`, so every element access is a spurious TS2339.

type L = { id: number; visible: boolean };

// Real-lib `Array.prototype.flat`: the receiver binds `A`, `D` defaults to 1.
declare const grid: L[][];
grid.flat().map((l) => l.id); // ok — element is L, not unknown
grid.flat().map((l) => l.visible); // ok
grid.flat().map((l) => l.nope); // TS2339 — element is concrete L

// Deeper nesting with an explicit depth.
declare const cube: L[][][];
cube.flat(2).map((l) => l.id); // ok

// Object.values over a string-index map, then flat: the value array flattens.
declare const byGroup: { [k: string]: L[] };
Object.values(byGroup)
  .flat()
  .map((l) => l.id); // ok

// A hand-written `this`-parameter generic infers from the receiver too.
interface Boxed<T> {
  unwrap<A>(this: A): A;
}
declare const boxed: Boxed<number> & L;
const back = boxed.unwrap();
const ok: L = back; // ok — A inferred as the receiver type
