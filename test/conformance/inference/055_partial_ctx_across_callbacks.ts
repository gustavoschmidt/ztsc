// A generic call's callback arguments are contextually typed by the signature's
// parameter with the inferences made SO FAR substituted in. The pass that types
// them used a snapshot taken before any callback ran, so a type parameter first
// learned from an earlier CALLBACK argument stayed the `any` placeholder for
// every callback to its right — and `any` absorbs the union it sits in, so
// `T | ((selected: boolean) => T)` collapsed to plain `any`. The arrow written
// for it then got no contextual signature and its parameters went implicit-any.
declare function use(x: unknown): void;

interface El {
  fill: string;
}
declare const els: readonly El[];

declare function getFormValue<T extends string>(
  elements: readonly El[],
  getAttribute: (element: El) => T,
  isRelevant: true | ((element: El) => boolean),
  defaultValue: T | ((isSomeSelected: boolean) => T),
): T;

// `T` is learned from `getAttribute`'s return, so `defaultValue`'s contextual
// type is `string | ((isSomeSelected: boolean) => string)` — one callable
// constituent, hence a contextual signature for the arrow.
const a = getFormValue(
  els,
  (element) => element.fill,
  (element) => element.fill.length > 0,
  (hasSelection) => (hasSelection ? "a" : "b"),
);
const okA: string = a;

// The context really flows: the parameter is `boolean`, not `any`.
const b = getFormValue(
  els,
  (element) => element.fill,
  true,
  (hasSelection) => {
    const wrong: string = hasSelection;
    use(wrong);
    return "a";
  },
);
use(b);

// A plain (non-callback) source for `T` behaved correctly already — pin it.
declare function seeded<T extends string>(
  seed: T,
  defaultValue: T | ((isSomeSelected: boolean) => T),
): T;
const c = seeded("x", (hasSelection) => {
  const wrong: number = hasSelection;
  use(wrong);
  return "x";
});
use(c);
