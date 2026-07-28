// Negatives for decomposing an aliased `&&` / `||`. Only one polarity of each
// operator says anything: `a && b` false and `a || b` true leave the subject
// alone, and an alias that is not a `const` without an annotation still does
// not narrow at all.
type Img = { type: "image"; fileId: string };
type Rect = { type: "rectangle" };
type El = Img | Rect;
declare function isImg(e: El): e is Img;
declare const files: Record<string, { v: number }>;
declare const flag: boolean;

// `&&` FALSE says nothing: either operand could be the falsy one.
export const a = (e: El) => {
  const data = isImg(e) && files[e.fileId];
  if (!data) {
    return e.fileId; // error: 'fileId' not on El
  }
  return "";
};

// `||` TRUE says nothing.
export const b = (e: El) => {
  const some = isImg(e) || flag;
  if (some) {
    return e.fileId; // error: 'fileId' not on El
  }
  return "";
};

// an annotated alias does not narrow (tsc requires no type annotation)
export const c = (e: El) => {
  const data: unknown = isImg(e) && files[e.fileId];
  if (data) {
    return e.fileId; // error: 'fileId' not on El
  }
  return "";
};

// a `let` alias does not narrow either
export const d = (e: El) => {
  let data = isImg(e) && files[e.fileId];
  if (data) {
    return e.fileId; // error: 'fileId' not on El
  }
  return "";
};
