function f(x: "a" | "b" | "c"): "b" | "c" {
  if (x === "a") { return "b"; }
  return x;
}
