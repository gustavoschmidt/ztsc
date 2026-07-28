// A destructuring *assignment* narrows each target by the type of the position
// it takes (tsc's `getAssignedType` walks the target), instead of resetting the
// target to its declared type.
declare const attr: string | null;
declare const m: RegExpMatchArray | null;

// array positions through an interface over Array<string>
export const a = () => {
  let width = attr;
  let height = attr;
  width = width || "50";
  height = height || "50";
  if (m) {
    [, width, height] = m;
  }
  return width.length + height.length;
};

// tuple positions
export const b = () => {
  let p: string | null = attr;
  let q: number | null = null;
  p = p || "x";
  [p, q] = ["a", 2] as [string, number];
  return p.length + q;
};

// object property target
export const c = () => {
  let v: string | null = attr;
  v = v || "x";
  ({ k: v } = { k: "y" });
  return v.length;
};

// object shorthand target
export const d = () => {
  let k: string | null = attr;
  k = k || "x";
  ({ k } = { k: "y" });
  return k.length;
};

// nested target
export const e = () => {
  let n: string | null = attr;
  n = n || "x";
  [[n]] = [["y"]] as [[string]];
  return n.length;
};

// a rest target takes an array of the element type
export const f = () => {
  let rest: string[] | null = null;
  [, ...rest] = ["a", "b", "c"];
  return rest.length;
};
