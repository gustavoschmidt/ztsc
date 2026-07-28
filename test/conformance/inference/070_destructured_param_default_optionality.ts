// A parameter whose NAME is an object binding pattern and which has an
// initializer takes its type from the initializer — but every property the
// pattern destructures WITH A DEFAULT is optional there, because the default
// supplies it and the caller need not.
//
// tsc reaches that from the other side: the initializer is contextually typed
// by the pattern's implied type (where a defaulted name is optional) and
// `checkObjectLiteral` copies the `Optional` flag onto each matching literal
// property. ztsc used the widened initializer type unchanged, so every
// property came out REQUIRED and calling `f({ w: 5 })` reported TS2345.

export const both = ({ w = 1, h = 2 } = { w: 0, h: 0 }) => [w, h];
export const partial = both({ w: 5 });
export const empty = both({});
export const none = both();
export const full = both({ w: 5, h: 6 });

// Only the defaulted names become optional; a destructured name without a
// default stays required, so this call is missing `h`.
export const mixed = ({ w = 1, h } = { w: 0, h: 0 }) => [w, h];
export const mixedOk = mixed({ h: 1 });

// A renamed binding keys off the PROPERTY name, not the local one.
export const renamed = ({ w: width = 1, h: height = 2 } = { w: 0, h: 0 }) => [
  width,
  height,
];
export const renamedPartial = renamed({ w: 5 });

// Inside the body the defaults have run, so the locals are the property types
// outright — optionality moved, nothing else did.
export const inBody = ({ w = 1, h = 2 } = { w: 0, h: 0 }) => {
  const nw: number = w;
  const nh: number = h;
  return nw + nh;
};
export const wrongLocal = ({ w = 1 } = { w: 0 }) => {
  const s: string = w;
  return s;
};

// (A wholly unrelated argument — `both(42)` — is NOT probed here: with every
// property optional the parameter is a WEAK type, and ztsc implements tsc's
// weak-type check (TS2559) only for JSX spreads. That under-report is
// pre-existing and orthogonal; it just becomes reachable through this shape.)

// The annotated control, which never went through this path.
export const annotated = (
  { w = 1, h = 2 }: { w?: number; h?: number } = {},
) => [w, h];
export const annotatedPartial = annotated({ w: 5 });

// No initializer: the annotation's own optionality applies and nothing here
// changes it.
export const noInit = ({ w = 1, h = 2 }: { w?: number; h?: number }) => [w, h];
export const noInitPartial = noInit({ w: 5 });
