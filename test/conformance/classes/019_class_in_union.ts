class A { kind: "a" = "a"; onlyA(): number { return 1; } }
class B { kind: "b" = "b"; onlyB(): string { return "s"; } }
function f(x: A | B): number {
  if (x.kind === "a") { return x.onlyA(); }
  x.onlyB();
  return 0;
}
