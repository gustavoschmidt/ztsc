// An aliased condition reaches the narrower as an expression, bypassing the
// binder's decomposition of `!` into a pair of flow nodes — so the narrower
// itself has to flip the sense for a `!` initializer, the same way it already
// handles `&&` / `||` operands (tsc `narrowType`, PrefixUnaryExpression arm).
type Box = { a: number };
declare function f(): Box | null;
declare function g(): Box | undefined;

// `!!x` alias, consumed negated
export const a = () => {
  const v = f();
  const isActive = !!v;
  if (!isActive) return 0;
  return v.a;
};

// `!!x` alias, consumed positively
export const b = () => {
  const v = f();
  const isActive = !!v;
  if (isActive) return v.a;
  return 0;
};

// single `!` alias — the polarity is the other way round
export const c = () => {
  const v = f();
  const missing = !v;
  if (missing) return 0;
  return v.a;
};

// `!` over a comparison, not just over a reference
export const d = () => {
  const v = g();
  const notThere = !(v !== undefined);
  if (notThere) return 0;
  return v.a;
};

// alias of an alias: the chain of `!`s still resolves
export const e = () => {
  const v = f();
  const missing = !v;
  const present = !missing;
  if (present) return v.a;
  return 0;
};

// a non-`!` prefix operator says nothing about its operand, and the alias
// must not narrow through it
export const h = (n: number) => {
  const v = f();
  const neg = -n;
  if (neg) return v.a; // TS18047
  return 0;
};
