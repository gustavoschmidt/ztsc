// The context a standard decorator receives is not just the
// `Class*DecoratorContext` interface: tsc intersects it with what it knows
// about THIS member — `{ name: <literal>; private: <bool>; static: <bool> }`
// — so an inline decorator reads the member's own name and modifiers as
// literal types, not as `string | symbol` and `boolean`.
class C {
  @((target, context) => {
    const n: "m" = context.name;
    const p: false = context.private;
    const s: false = context.static;
    return target;
  })
  m(x: number) {
    return x;
  }

  @((target, context) => {
    const n: "sf" = context.name;
    const s: true = context.static;
  })
  static sf = 1;

  @((target, context) => {
    const n: "#p" = context.name;
    const p: true = context.private;
    const s: false = context.static;
    return target;
  })
  #p() {}

  @((target, context) => {
    const n: "g" = context.name;
    const s: true = context.static;
    return target;
  })
  static get g() {
    return 1;
  }

  @((target, context) => {
    const n: "a" = context.name;
    const p: false = context.private;
  })
  accessor a = 1;
}

// A wrong literal is still reported — the override narrows the context, it
// does not silence it.
class D {
  @((target, context) => {
    const n: "wrong" = context.name;
    const s: true = context.static;
    return target;
  })
  right() {}
}
