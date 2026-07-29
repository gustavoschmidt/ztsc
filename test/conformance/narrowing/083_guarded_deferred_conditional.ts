// `x !== undefined` on a value whose type is a still-deferred conditional (or
// indexed access) has to subtract the `undefined` hiding in the type's
// constraint, and the guarded and unguarded results must join back into one
// usable type: tsc narrows through `getAdjustedTypeWithFacts` and then reduces
// `X & {} | X` to `X`.

type Shapes = { rect: { d: string }; ellipse: { e: number } };
type El = { type: "rect" } | { type: "ellipse" } | { type: "sel" };
type NonSel = Exclude<El, { type: "sel" }>;

const get = <T extends El>(element: T) => {
  return {} as T["type"] extends keyof Shapes
    ? Shapes[T["type"]] | undefined
    : unknown;
};

const gen = <T extends NonSel>(element: T) => {
  const cached = get(element);
  if (cached !== undefined) {
    return cached;
  }
  return {} as T["type"] extends keyof Shapes ? Shapes[T["type"]] : { d: string };
};

declare const rect: { type: "rect" };
const shape = gen(rect);
shape.d;

// The same join reached through a deferred indexed access.
type Box = { a: { d: string } | undefined; b: { d: string } | undefined };
const pick = <K extends keyof Box>(k: K) => {
  const held: Box[K] = {} as Box[K];
  if (held !== undefined) {
    return held;
  }
  return {} as { d: string };
};
declare const ka: "a";
pick(ka).d;

// An access that CANNOT be undefined keeps its deferred spelling: narrowing a
// union of it with `undefined` must leave the member itself alone.
type Sure = { a: { d: string }; b: { d: string } };
const opt = <K extends keyof Sure>(k: K, v: Sure[K] | undefined) => {
  if (v !== undefined) {
    return v;
  }
  return {} as Sure[K];
};
opt(ka, { d: "" }).d;
