// Negatives for the guarded-deferred-conditional narrowing: the guard must not
// hand back a type that lost its deferred spelling, and the absorbed union must
// still refuse what the underlying type refuses.

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

// The instantiated result is `{ d: string }` — not `unknown`, not `undefined`,
// and not the other member of `Shapes`.
const bad1: null = shape;
shape.e;

// Before the guard the `undefined` arm is still there.
const before = <T extends NonSel>(element: T) => {
  const cached = get(element);
  return cached.d;
};

// The guard subtracts `undefined`, it does not widen to the constraint: a
// caller that asked for `ellipse` still gets `ellipse`'s shape.
declare const ellipse: { type: "ellipse" };
const bad2: { d: string } = gen(ellipse);
