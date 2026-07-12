declare const c: boolean;
function pick(x: number, y: string) {
  if (c) { return x; }
  return y;
}
const u: string | number = pick(1, "a");
