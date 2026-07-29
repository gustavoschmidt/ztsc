// Negatives for 087: a parameter the inference reached at the TOP LEVEL of the
// parameter type still widens its fresh literal, and a union or intersection
// in the parameter type does not bury it (tsc's `isTypeParameterAtTopLevel`
// descends both).

declare function state<S>(initial: S | (() => S)): [S, (next: S) => void];
declare function pair<T>(a: T, b: T): [T, T];
declare function boxed<T>(x: { v: T }): [T];

export function widensAtTopLevel() {
  // `S | (() => S)` keeps S at top level: `false` widens to `boolean`, so a
  // later `true` is accepted.
  const [, setFlag] = state(false);
  setFlag(true);

  // Two plain top-level parameters: still widened.
  const p = pair(1, 2);
  const n: [number, number] = p;

  // Buried in an object property — but the literal is widened before the
  // candidate is ever formed, by the object literal's own mutable-location
  // rule, so the top-level flag never gets to matter here.
  const b = boxed({ v: true });
  const t: [true] = b; // TS2322: [boolean]
  return [n, t];
}
