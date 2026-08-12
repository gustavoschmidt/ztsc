// WHERE a type argument is written must not decide whether its constraint is
// checked. Four sites write a list, all four are one question, and tsc reports
// all four:
//
//   * a type reference,             `type A = G<Bad>`
//   * a class heritage clause,      `class D extends G<Bad> {}`
//   * an interface heritage clause, `interface I extends G<Bad> {}`
//   * an explicit list on a call,   `f<Bad>(x)`
//
// ztsc used to queue the gate from `typeFromTypeNode` alone, so only the type
// reference was checked — the root of outline's twelve missing TS2344 keys
// (`Collection`/`Document` against `Store<T extends Model>`), every one of them
// an `extends` clause or an explicit call list. The relation fact was never the
// gap: the alias case here decided it correctly all along. `baseClassRef`,
// `interfaceHeritageTypes` and `resolveSignatureCall` now reach it too, each
// from the point where the clause's arguments are converted.

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
