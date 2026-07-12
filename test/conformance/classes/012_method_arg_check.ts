class Calc {
  add(a: number, b: number): number { return a + b; }
}
const c = new Calc();
c.add(1, 2);
c.add(1, "x");
