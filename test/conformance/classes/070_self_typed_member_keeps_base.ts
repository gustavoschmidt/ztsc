// A class whose OWN members are typed through itself must not lose its
// inherited members.
//
// Materializing `execute` re-enters `Del`'s own member table (`this["prepare"]`
// indexes back into the class), so the fold of `extends QP` runs while `QP`'s
// table is in turn materializing and cuts at the in-progress guard. The cut
// answer used to be memoized, which made the instance PERMANENTLY `err` — and
// an `err` instance is vacuously assignable, so the `implements` verdict below
// silently passed. The cut is now never memoized: the first reader outside the
// cycle recomputes the real table. This is drizzle's select/delete builder
// shape (`execute: ReturnType<this['prepare']>['execute']`) reduced.
interface SQLWrapper {
  getSQL(): string;
}
declare abstract class QP<T> {
  then(): void;
  abstract execute(): Promise<T>;
}
type AnyDel = Del<unknown>;
type Prep<T extends AnyDel> = {
  execute: () => Promise<T["_"]["q"]>;
  iterator: never;
};
export interface Del<TQ> extends QP<TQ> {
  readonly _: {
    readonly q: TQ;
  };
}
// `getSQL` is missing: TS2420, and it is only reachable because the instance
// type is a real object rather than the cycle cut.
export declare class Del<TQ> extends QP<TQ> implements SQLWrapper {
  prepare(): Prep<this>;
  execute: ReturnType<this["prepare"]>["execute"];
  iterator: ReturnType<this["prepare"]>["iterator"];
}

// The same table read from a USE site: every inherited member is present, and
// a name that is on no base is still absent.
declare const d: Del<string>;
export const a: () => void = d.then;
export const b: number = d.then;
export const c = d.nope;

// The base-fold cut itself, entered from the BASE: materializing `Base2`'s
// members reaches `Node2`, whose fold of `extends Base2` then runs while
// `Base2` is still in progress and cuts. `Node2` must not keep the resulting
// baseless table — `shared` is inherited and has to survive.
declare class Base2<T> {
  shared: T;
  // An INDEXED ACCESS, not a bare reference: it forces `Node2`'s whole table
  // to materialize here, inside `Base2`'s own.
  derive(): Node2["own"];
}
declare class Node2 extends Base2<string> {
  own(): number;
}
declare const n: Node2;
export const e: string = n.shared;
export const f: number = n.shared;
