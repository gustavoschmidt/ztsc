// WHERE a type argument is written decides whether its constraint is checked.
//
// ztsc queues the TS2344 gate from `typeFromTypeNode` (see
// `queueTypeArgConstraints`), which covers a type reference written in a TYPE
// position — the alias below. Three other written argument lists never reach
// the queue:
//
//   * a class heritage clause,      `class D extends G<Bad> {}`
//   * an interface heritage clause, `interface I extends G<Bad> {}`
//   * an explicit list on a call,   `f<Bad>(x)`
//
// All four sites are one question, and tsc reports all four. The three that
// ztsc misses are registered in test/conformance/DEFERRED; they are the root of
// outline's twelve missing TS2344 keys (`Collection`/`Document` against
// `Store<T extends Model>`), the fact itself being one ztsc already decides
// correctly — the alias case proves it.

abstract class Model {
    id = "";
    store!: Store<Model>;
}

abstract class Store<T extends Model> {
    add = (item: T): T => item;
}

class Sub extends Model {
    declare store: SubStore;
    extra = "";
}

class SubStore extends Store<Sub> {
    only!: Sub[];
    onlyToo!: string;
}

// --- checked: a written argument in a TYPE position --------------------
type Constrain<T extends Model> = T;
export type Alias = Constrain<Sub>;

// --- unchecked: heritage clauses --------------------------------------
export class ViaClassHeritage extends Store<Sub> {}
export interface ViaInterfaceHeritage extends Store<Sub> {}

// --- unchecked: an explicit list on a call ----------------------------
declare function take<T extends Model>(x: T): void;
declare const sub: Sub;
take<Sub>(sub);
