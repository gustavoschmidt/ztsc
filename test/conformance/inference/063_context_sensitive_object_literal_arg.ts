// A CONTEXT-SENSITIVE object-literal argument of a GENERIC call — one carrying
// a callback with un-annotated parameters — must be typed by the parameter.
//
// The non-generic form of the same call types the argument by the parameter
// directly and was always fine; the generic path checked it context-free
// (contextual typing was gated to the literal-keeping inference shape), so
// every callback parameter inside it fell to implicit `any` — TS7006 at call
// sites that are correct TypeScript.
//
// The literal cannot simply be handed the parameter either: the type
// parameters are inferred from this very argument. Two passes, as tsc runs
// them — a provisional context-free pass whose `any`s are wildcards, then the
// authoritative pass against the parameter with those inferences substituted.

type X = { id: string };

// POSITIVE (must NOT error) --------------------------------------------------

// The parameter really is typed, not `any`: reading a non-existent property of
// it is an error, which is the point of the case.
declare function plain<T>(props: { v: T; onChange: (value: T) => void }): void;
export const p1 = plain({
  v: "x",
  onChange: (value) => {
    const s: string = value;
    void s;
  },
});

// `Base & (VariantA | VariantB)` — the discriminated-props idiom.
type Base<T> = { options: { value: T }[]; value: T | null };
type Variants<T> =
  | { type?: "radio"; group: string; onChange: (value: T) => void }
  | { type: "button"; onClick: (value: T, event: number) => void };
declare function sel<T>(props: Base<T> & Variants<T>): void;
export const p2 = sel({
  group: "g",
  options: [{ value: "x" }],
  value: "x",
  onChange: (value) => {
    const s: string = value;
    void s;
  },
});
export const p3 = sel({
  type: "button",
  options: [{ value: "x" }],
  value: "x",
  onClick: (value, event) => {
    const s: string = value;
    const n: number = event;
    void s;
    void n;
  },
});

// A union parameter (no intersection).
declare function uni<T>(
  props: { v: T; onChange: (value: T) => void } | { v: T; onClick: () => void },
): void;
export const p4 = uni({
  v: "x",
  onChange: (value) => {
    const s: string = value;
    void s;
  },
});

// A type parameter the argument cannot infer takes its CONSTRAINT in the
// callback's contextual type, not a bare type variable — so comparing the
// callback parameter against a member of that constraint is legal.
declare function keyed<T extends Record<keyof T, number>, K extends keyof T>(o: {
  values: T;
  interpolate: (from: number, key: K) => number | undefined;
}): void;
export const p5 = keyed({
  values: { a: 1, b: 2 },
  interpolate: (from, key) => {
    if (key === "a") {
      return from;
    }
    return undefined;
  },
});

// Regression: a fully ANNOTATED callback property is not context sensitive and
// is unaffected.
export const p6 = plain({
  v: "x",
  onChange: (value: string) => {
    void value;
  },
});

// Regression: the non-generic form still works.
declare function conc(props: { v: string; onChange: (v: string) => void }): void;
export const p7 = conc({
  v: "x",
  onChange: (value) => {
    const s: string = value;
    void s;
  },
});

// NEGATIVE (must error) ------------------------------------------------------

// The callback parameter is the inferred type, so a wrong use of it is caught.
export const n1 = plain({
  v: "x",
  onChange: (value) => {
    const n: number = value; // TS2322
    void n;
  },
});

// And the argument is still checked against the parameter.
export const n2 = plain({
  v: "x",
  onChange: 5, // TS2322
});
