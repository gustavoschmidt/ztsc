// A homomorphic mapped type over a CLASS STATIC SIDE (`{ [P in keyof T]: … }`
// with `T = typeof C`) maps the class's static members — the same key set
// `keyof typeof C` answers, inherited statics included, non-public statics
// excluded.
//
// ztsc modelled `typeof C` as a nominal `.class_value` shortcut carrying no
// properties of its own (every reader materializes them on demand), so the
// homomorphic map fell through to `{}` while `keyof typeof C` still answered
// the full static key set. Everything built on the pair then degenerated:
// sequelize's `ModelStatic<M>` is
//
//   type NonConstructorKeys<T> = { [P in keyof T]: T[P] extends new () => any ? never : P }[keyof T];
//   type ModelStatic<M> = Pick<typeof Model, NonConstructorKeys<typeof Model>> & { new (): M };
//
// and with the map empty the indexed access answered `unknown`, `Pick<T,
// unknown>` gave `{}`, and `ModelStatic<M>` became exactly `{ new (): M }` —
// every static call through it a TS2339 (62 of them on outline).

class Base {
  static baseTag = "b";
  static baseMake(): Base {
    return new Base();
  }
  id = 1;
}

class Model extends Base {
  private static hidden = 1;
  protected static guarded = 2;
  static findAll(): Model[] {
    return [];
  }
  static findByPk(_id: string): Model | null {
    return null;
  }
  static label = "model";
  name = "";
}

// The map has the statics as properties, own and inherited.
type Statics = { [P in keyof typeof Model]: (typeof Model)[P] };
declare const st: Statics;
export const s1: () => Model[] = st.findAll;
export const s2: string = st.label;
export const s3: string = st.baseTag;
export const s4: () => Base = st.baseMake;
// …not the non-public ones, and not a name the class never declares.
export const s5 = st.hidden; // TS2339
export const s6 = st.guarded; // TS2339
export const s7 = st.nope; // TS2339
// …and a mapped property keeps its type: a static method is not a string.
export const s8: string = st.findAll; // TS2322

// Modifiers apply as they do over any other source.
type PartialStatics = { [P in keyof typeof Model]?: (typeof Model)[P] };
declare const ps: PartialStatics;
export const p1: (() => Model[]) | undefined = ps.findAll;
export const p2: () => Model[] = ps.findAll; // TS2322

// A remap (`as`) sees the static keys too.
type Renamed = { [P in keyof typeof Model as P extends "label" ? "tag" : never]: (typeof Model)[P] };
declare const rn: Renamed;
export const r1: string = rn.tag;
export const r2 = rn.label; // TS2339

// The map carries NO construct signature: `keyof typeof C` covers the static
// properties, and a mapped type never reproduces call/construct signatures.
export const r3 = new st(); // TS2351

// The value template may read anything off the source, not just `T[P]`.
type KeyNames = { [P in keyof typeof Model]: P };
declare const kn: KeyNames;
export const k1: "findAll" = kn.findAll;
export const k2: "label" = kn.findAll; // TS2322

// A static side reached as an INTERSECTION constituent: `keyof (typeof C & X)`
// is `keyof typeof C | keyof X`, so the map has both sides' members.
type Extra = { extra: number };
type Both = { [P in keyof (typeof Model & Extra)]: (typeof Model & Extra)[P] };
declare const bo: Both;
export const b1: string = bo.label;
export const b2: number = bo.extra;
export const b3 = bo.nope; // TS2339

// The same idiom over a NAMESPACE value (`typeof N`), which ztsc models the
// same way.
namespace N {
  export const a = 1;
  export function f(): string {
    return "";
  }
}
type NsMapped = { [P in keyof typeof N]: (typeof N)[P] };
declare const ns: NsMapped;
export const n1: number = ns.a;
export const n2: () => string = ns.f;
export const n3 = ns.missing; // TS2339
