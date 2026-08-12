// A class INSTANCE method's `this` is POLYMORPHIC: tsc types the `this`
// expression inside it as the class's this-type, so a return type DERIVED from
// `this` stays parameterized on the receiver instead of collapsing to the
// declaring class. `foo(): this` was already kept as a marker; the INFERRED
// return type is the same rule with the annotation left off.
//
// sequelize's `save(options?): Promise<this>` behind outline's model base class
// is the shape that forces it — a `saveWithCtx` that merely forwards `save`
// handed every caller the base class back.
//
// Oracle: tsgo 7.0.2 reports exactly the marked lines.

class Base {
  save(): Promise<this> {
    return Promise.resolve(this);
  }

  // (a) forwarding a `this`-returning method — inferred `Promise<this>`
  saveWithCtx() {
    return this.save();
  }

  // (b) returning `this` outright — inferred `this`
  self() {
    return this;
  }

  // (c) `this` nested inside an object literal — inferred `{ me: this }`
  wrap() {
    return { me: this };
  }

  // (d) `typeof this` in an annotation inside the body still rides out
  partial() {
    const out: Partial<typeof this> = {};
    return out;
  }

  // (e) an explicit `this` PARAMETER is a written override of the receiver and
  // must win over the polymorphic form: the return is `Base`, never `this`.
  pinned(this: Base) {
    return this;
  }

  // (f) a STATIC's receiver is the class value, which has no polymorphic form
  // here: `Base`, not `this`.
  static make() {
    return new Base();
  }
}

class Sub extends Base {
  name!: string;
}

declare const s: Sub;
declare const b: Base;

async function a_ok() {
  const r = await s.saveWithCtx();
  return r.name; // resolves on Sub
}

const b_self = s.self();
const b_ok: string = b_self.name;

const c_wrap = s.wrap();
const c_ok: string = c_wrap.me.name;

const d_part = s.partial();
const d_ok: string | undefined = d_part.name;

// The base receiver still gets the base class, so a subclass member is absent.
const e_base = b.self();
const e_bad: string = e_base.name; // TS2339

// (e): the explicit `this` parameter pins the return to `Base`.
const f_pinned = s.pinned();
const f_bad: string = f_pinned.name; // TS2339

// (f): a static returns the annotated/constructed type.
const g_static = Base.make();
const g_bad: string = g_static.name; // TS2339

// A `this`-typed value is still assignable to the declaring class.
const h_ok: Base = s.self();

export { a_ok, b_ok, c_ok, d_ok, e_bad, f_bad, g_bad, h_ok };
