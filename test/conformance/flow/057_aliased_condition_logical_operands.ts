// An aliased condition is handed to the narrower as an expression, bypassing
// the binder's decomposition, so the narrower itself has to know that `a && b`
// being true means both operands are true and `a || b` being false means both
// are false (tsc `narrowTypeByBinaryExpression`).
type Img = { type: "image"; fileId: string };
type Rect = { type: "rectangle" };
type El = Img | Rect;
declare function isImg(e: El): e is Img;
declare const files: Record<string, { v: number }>;
declare const els: readonly El[];

// `&&` initializer, true branch
export const a = () => {
  const out: string[] = [];
  for (const e of els) {
    const data = isImg(e) && files[e.fileId];
    if (data) {
      out.push(e.fileId);
    }
  }
  return out;
};

// same outside a loop
export const b = (e: El) => {
  const data = isImg(e) && files[e.fileId];
  if (data) {
    return e.fileId;
  }
  return "";
};

// the alias used as the left operand of a further `&&`
export const c = (e: El) => {
  const data = isImg(e) && files[e.fileId];
  if (data && data.v !== 1) {
    return e.fileId;
  }
  return "";
};

// `||` false branch: both operands are falsy, so both guards' negations hold
declare function isRect(e: El): e is Rect;
export const d = (e: El) => {
  const other = isRect(e) || isRect(e);
  if (!other) {
    return e.fileId;
  }
  return "";
};

// chained `&&` operands
export const e2 = (e: El, flag: boolean) => {
  const data = flag && isImg(e) && files[e.fileId];
  if (data) {
    return e.fileId;
  }
  return "";
};
