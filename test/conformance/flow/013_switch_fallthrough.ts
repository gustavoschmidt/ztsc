function f(x: "a" | "b" | "c"): number {
  let n: number = 0;
  switch (x) {
    case "a":
    case "b": n = 1; break;
    case "c": n = 2; break;
  }
  return n;
}
