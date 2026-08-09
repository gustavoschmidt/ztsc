// The polarity `057` does not cover: `a || b` being TRUE, and `a && b` being
// FALSE, are each a union of the two ways the operator can land — tsc's
// `narrowTypeByBinaryExpression` returns
//   `||` true  = union(narrow(left, true), narrow(narrow(left, false), right, true))
//   `&&` false = union(narrow(left, false), narrow(narrow(left, true), right, false))
// When every arm removes the same constituent, the union removes it too.
type St = { status: "x" | "y" | "z"; n: number };
declare function get(): St | undefined;
declare function box(): { a: number } | null;

// both arms of a `||` reject `undefined`, so the true branch does too
export const a = () => {
  const s = get();
  const terminal = s?.status === "x" || s?.status === "y";
  if (terminal) return s.n;
  return 0;
};

// `a || b` false: the existing polarity, still correct
export const b = () => {
  const s = get();
  const absent = s === undefined || s.status === "z";
  if (!absent) return s.n;
  return 0;
};

// `a && b` false, where the left operand alone settles it on one side and the
// left-true/right-false path settles it on the other
export const c = () => {
  const s = get();
  const both = s !== undefined && s.status === "x";
  if (both) return s.n;
  return 0;
};

// three-way `||`
export const d = () => {
  const s = get();
  const any3 = s?.status === "x" || s?.status === "y" || s?.status === "z";
  if (any3) return s.n;
  return 0;
};

// a `||` arm that constrains nothing leaves the union at the declared type
export const e = (flag: boolean) => {
  const s = get();
  const loose = s?.status === "x" || flag;
  if (loose) return s.n; // TS18048
  return 0;
};

// same for `&&` in the false polarity
export const h = (flag: boolean) => {
  const v = box();
  const some = flag && v !== null;
  if (!some) return v.a; // TS18047
  return 0;
};
