// Higher-order rewrite (M20a): an own type param whose *constraint* references
// the enclosing interface's param through a reducible operator
// (`<K extends keyof T>`) — the react-hook-form / idb "constrained field key"
// shape, in the form ztsc reduces. Instantiating the interface substitutes `T`,
// so the fresh param minted for `K` is constrained by the concrete `keyof Obj`:
// a real key is accepted (and indexes to its member type), a non-key rejected.
interface Getter<T> {
  <K extends keyof T>(key: K): T[K];
}
type Obj = { id: number; name: string };
declare const get: Getter<Obj>;

const a: number = get("id"); // clean
const b: string = get("name"); // clean
const c: number = get("name"); // TS2322: string not number
const d = get("missing"); // TS2345: "missing" not assignable to keyof Obj
