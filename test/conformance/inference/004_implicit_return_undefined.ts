declare const c: boolean;
function maybe(x: number) {
  if (c) { return x; }
}
const u: number | undefined = maybe(1);
const bad: number = maybe(2);
