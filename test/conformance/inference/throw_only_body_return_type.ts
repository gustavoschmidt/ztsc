// tsc's `mayReturnNever`: a body with no `return` at all whose endpoint is
// unreachable infers `never` only for an ARROW, a function EXPRESSION, or an
// OBJECT-LITERAL method. A function DECLARATION and every class member —
// method, accessor, static — infer `void` from the same body.
type WantsNever = () => never;
type WantsVoid = () => void;

// --- arrow: never
const arrow = () => {
  throw new Error("x");
};
export const a1: WantsNever = arrow;

// --- function expression: never
const fnExpr = function () {
  throw new Error("x");
};
export const a2: WantsNever = fnExpr;

// --- object-literal method: never
const obj = {
  m() {
    throw new Error("x");
  },
};
export const a3: WantsNever = obj.m;

// --- function declaration: void
function decl() {
  throw new Error("x");
}
export const a4: WantsNever = decl;
export const a5: WantsVoid = decl;

// --- class method / accessor / static: void
class K {
  m() {
    throw new Error("x");
  }
  get g() {
    throw new Error("x");
  }
  static s() {
    throw new Error("x");
  }
}
declare const k: K;
export const a6: WantsNever = k.m;
export const a7: WantsVoid = k.m;
export const a8: never = k.g;
export const a9: WantsNever = K.s;

// The shape it was found on: an abstract-ish base whose method is a throwing
// stub, overridden by a subclass that actually implements it. `void` for the
// base keeps the subclass assignable to it; `never` would not.
class NBase {
  render(_s: string) {
    throw new Error("not implemented");
  }
}
class NSub extends NBase {
  render(_s: string) {
    return;
  }
}
declare const ns: NSub;
export const a10: NBase = ns;
