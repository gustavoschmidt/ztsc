// A static accessor whose body initializes the field it narrows, reached
// through a cycle.
//
// `get registered()` narrows `_r` by assigning `init()`'s result to it, so its
// type depends on `init`'s inferred return type. Inferring that walks the flow
// of `init`'s body, and a call STATEMENT on that path is an effects-signature
// probe: the callee's declared type is resolved to see whether it asserts
// anything. Resolving `F.reg.call` that way materialized ALL of `typeof F` —
// including `registered`, whose own resolution is what asked for `init` in the
// first place. `init` then answered `any` (the `typeOfSymbol` cycle break), the
// assignment reduced to nothing, and the getter kept its declared `Map | undefined`
// — cached, so every later `F.registered.get(…)` was `possibly undefined`.
//
// tsc's probe (`getEffectsSignature` -> `getTypeOfDottedName`) resolves one
// property symbol and only ever consults an ANNOTATED return type, so it never
// forces an inferred return; it reports nothing here. ztsc's equivalent: while
// a class side is mid-materialization the probe answers "no information"
// instead of building the table, and a plain-name callee that is an
// unannotated variable is not resolved at all (tsc's
// `isDeclarationWithExplicitTypeAnnotation`).
declare function use(x: unknown): void;

// POSITIVE (must NOT error) --------------------------------------------------

// The cycle: static getter -> init -> effects probe on `F.reg.call` -> `reg`'s
// inferred return -> `this.registered` (the F arm is the INSTANCE getter) ->
// the static getter again.
class F {
  private static _r: Map<number, string> | undefined;
  public static get registered() {
    if (!F._r) {
      F._r = F.init();
    }
    return F._r;
  }
  public get registered() {
    return F.registered;
  }
  private static reg(this: F | { registered: Map<number, string> }) {
    return this.registered;
  }
  private static init() {
    const fonts = { registered: new Map<number, string>() };
    F.reg.call(fonts);
    return fonts.registered;
  }
}
use(F.registered.size);

// The same cycle with the call one level down, inside an unannotated arrow
// held by a `const`: the statement-position callee is now a plain name whose
// type would have to be inferred from an initializer.
class G {
  private static _r: Map<number, string> | undefined;
  public static get registered() {
    if (!G._r) {
      G._r = G.init();
    }
    return G._r;
  }
  public get registered() {
    return G.registered;
  }
  private static reg(
    this: G | { registered: Map<number, string> },
    family: string,
  ) {
    const found = this.registered.get(1);
    if (!found) {
      this.registered.set(1, family);
    }
    return this.registered;
  }
  private static init() {
    const fonts = { registered: new Map<number, string>() };
    const seed = (family: string) => {
      G.reg.call(fonts, family);
    };
    seed("a");
    return fonts.registered;
  }
}
use(G.registered.size);

// An `else if` re-assignment arm on the same shape: both writes reduce the
// declared type, so the getter is still the non-optional map.
class H {
  private static _r: Map<number, string> | undefined;
  private static _done = false;
  public static get registered() {
    if (!H._r) {
      H._r = H.init();
    } else if (!H._done) {
      H._r = new Map([...H.init().entries(), ...H._r.entries()]);
    }
    return H._r;
  }
  public get registered() {
    return H.registered;
  }
  private static reg(this: H | { registered: Map<number, string> }) {
    return this.registered;
  }
  private static init() {
    const fonts = { registered: new Map<number, string>() };
    H.reg.call(fonts);
    H._done = true;
    return fonts.registered;
  }
}
use(H.registered.size);

// Regression: a guard held by an unannotated `const` still narrows from inside
// an inferred-return function. Its predicate is a return-type ANNOTATION, so it
// is resolvable without inferring anything and stays available.
const isStr = (v: string | number): v is string => typeof v === "string";
declare const sn: string | number;
function p_const_guard() {
  if (isStr(sn)) {
    return sn.length;
  }
  return 0;
}
use(p_const_guard());

// Regression: an assertion function in statement position still narrows from
// inside an inferred-return function. This is the flow node the effects probe
// serves, so it is the one that must keep working.
declare function assertStr(v: string | number): asserts v is string;
function p_assert_stmt() {
  const v: string | number = sn;
  assertStr(v);
  return v.length;
}
use(p_assert_stmt());

// Regression: a predicate held by an object property is still found through a
// member callee, from inside an inferred-return function (narrowing/059's
// path — the receiver here is a plain object, on no cycle, so the probe
// resolves it exactly as before).
declare const obj: { isStr(v: string | number): v is string };
function p_member_guard() {
  if (obj.isStr(sn)) {
    return sn.length;
  }
  return 0;
}
use(p_member_guard());

// NEGATIVE (must error) ------------------------------------------------------

// The getter really can return `undefined`: nothing assigns `_r`, so the
// optionality the cycle used to fabricate must still be reported here.
class N1 {
  private static _r: Map<number, string> | undefined;
  public static get registered() {
    return N1._r;
  }
  public get registered() {
    return N1.registered;
  }
  private static reg(this: N1 | { registered: Map<number, string> }) {
    return this.registered;
  }
  private static init() {
    const fonts = { registered: new Map<number, string>() };
    N1.reg.call(fonts);
    return fonts.registered;
  }
}
use(N1.registered.size); // TS18048

// The guard's complement does not grant the other arm.
function n_wrong_arm() {
  if (isStr(sn)) {
    return 0;
  }
  return sn.length; // TS2339
}
use(n_wrong_arm());

// A name the class does not have is still not found through the cycle.
class N2 {
  private static _r: Map<number, string> | undefined;
  public static get registered() {
    if (!N2._r) {
      N2._r = N2.init();
    }
    return N2._r;
  }
  private static init() {
    return new Map<number, string>();
  }
}
use(N2.registered.nope); // TS2339

export { F, G, H, N1, N2 };
