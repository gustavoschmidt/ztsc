// sequelize's `ModelStatic<M>` idiom end to end: a homomorphic map over a class
// STATIC SIDE whose value branch filters by `extends new () => any`, indexed by
// `keyof T` to recover the surviving key names, and fed to a `Pick`.
//
// `NonConstructorKeys<typeof Model>` collapsed to `unknown` in ztsc (the
// homomorphic map over the nominal `.class_value` came out `{}`, and indexing
// `{}` gives `unknown`), so `Pick<T, unknown>` was `{}` and `ModelStatic<M>`
// degenerated to exactly `{ new (): M }`: every `Model.findAll()` /
// `Model.scope(…)` through it reported TS2339, and the argument checks tsc
// reports at those same calls went missing.
type Pick_<T, K extends keyof T> = { [P in K]: T[P] };

type NonConstructorKeys<T> = { [P in keyof T]: T[P] extends new () => any ? never : P }[keyof T];
type NonConstructor<T> = Pick_<T, NonConstructorKeys<T>>;

class Model {
  static findAll(): Model[] {
    return [];
  }
  static findByPk(_id: string): Model | null {
    return null;
  }
  static scope<M extends Model>(this: ModelStatic<M>, _s: string): ModelStatic<M> {
    return this;
  }
  id = "";
}

type ModelStatic<M extends Model> = NonConstructor<typeof Model> & { new (): M };

class Integration extends Model {
  service = "";
}

// The key set survives: a wider target accepts it, a narrower one does not.
type K = NonConstructorKeys<typeof Model>;
declare const k: K;
export const k1: "findAll" | "findByPk" | "scope" | "prototype" = k;
export const k2: "findAll" = k; // TS2322

// A constructor-typed member is filtered OUT by the `extends new () => any`
// branch — that is what the idiom is for.
type Holder = { plain: string; ctor: new () => Model; make(): Model };
type HK = NonConstructorKeys<Holder>;
declare const hk: HK;
export const h1: "plain" | "make" = hk;
export const h2: HK = "ctor"; // TS2322 (`ctor` is not in the key set)

// The whole chain: a static reached through `ModelStatic<M>`, including the
// `this`-typed `scope` that hands the static side back.
export const rows: Model[] = Integration.scope("withAuth").findAll();
export const one: Model | null = Integration.scope("withAuth").findByPk("1");
export const bad = Integration.scope("withAuth").nope(); // TS2339
// …and the arguments are still checked through it.
export const badArg = Integration.scope("withAuth").findByPk(1); // TS2345
// The construct signature of the intersection still constructs the instance.
const Ctor: ModelStatic<Integration> = Integration;
export const made: Integration = new Ctor();
export const madeWrong: string = new Ctor(); // TS2322
