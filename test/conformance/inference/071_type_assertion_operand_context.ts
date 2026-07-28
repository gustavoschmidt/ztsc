// A type assertion does not stop contextual typing. `expr as T` gives its
// operand `T` as the contextual type; `expr as const` gives it the OUTER
// contextual type, since a const assertion names no target of its own.
//
// The sibling `expr satisfies T` already did this. `as` threw the context away
// on both branches, so an arrow behind an assertion lost its contextual
// signature and every parameter reported TS7006 — while the same arrow written
// with a plain annotation, or merely parenthesized, was fine.

type Handler = (event: number) => void;

// Parenthesized without an assertion: the control that always worked.
export const annotated: Handler = (event) => {
  void event;
};

// `as T`: the operand's contextual type is T.
export const asserted = ((event) => {
  void event;
}) as Handler;

// And it really is T, not `any`.
export const assertedTyped = ((event) => {
  const n: number = event;
  void n;
}) as Handler;

export const assertedWrong = ((event) => {
  const s: string = event;
  void s;
}) as Handler;

type Api = { onChange: (cb: (x: number) => void) => void };

// `as const`: the operand keeps the OUTER contextual type.
export const api: Api = {
  onChange: (cb) => {
    void cb;
  },
} as const;

export const apiTyped: Api = {
  onChange: (cb) => {
    const f: (x: number) => void = cb;
    void f;
  },
} as const;

// A generic target: the assertion's own type parameter is the context.
export const generic = <T extends (event: number) => void>(x: T) => {
  void x;
  return ((event) => {
    void event;
  }) as T;
};

// The assertion's own comparability check still runs, and now sees the
// contextually typed operand.
export const bad = "s" as number;

// A nested object literal behind `as T` keeps its literal property types
// instead of widening.
type Shape = { kind: "circle" | "square"; r: number };
export const shape = { kind: "circle", r: 1 } as Shape;
