// A decorator expression is contextually typed by the call shape the runtime
// will invoke it with, so an inline `@((target, context) => …)` has NO
// implicit-any parameters — and the types that arrive are the real ones: the
// value side is the member's own type, the context side the
// `Class*DecoratorContext` for that position.
class C {
  @((target, context) => {
    const kind: "method" = context.kind;
    const n: number = target(1);
  })
  m(x: number): number {
    return x;
  }

  @((target, context) => {
    const kind: "field" = context.kind;
    const u: undefined = target;
  })
  f = 1;

  @((target, context) => {
    const kind: "getter" = context.kind;
    const n: number = target();
  })
  get g() {
    return 1;
  }

  @((target, context) => {
    const kind: "setter" = context.kind;
    target("s");
  })
  set s(v: string) {}

  @((target, context) => {
    const kind: "accessor" = context.kind;
  })
  accessor a = 1;

  @((target, context) => {
    const isStatic: boolean = context.static;
    const isPrivate: boolean = context.private;
  })
  static sm() {}
}

@((target, context) => {
  const kind: "class" = context.kind;
  const name: string | undefined = context.name;
})
class D {}

// The contextual type is a real type, not a blanket suppression of TS7006:
// the wrong literal for `kind` and a bad call through `target` are both still
// reported.
class E {
  @((target, context) => {
    const kind: "field" = context.kind;
    target("no");
  })
  m2(x: number) {}
}
