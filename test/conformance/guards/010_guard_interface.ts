interface Cat { meow(): void; }
function isCat(x: object): x is Cat { return "meow" in x; }
function f(v: object): void {
  if (isCat(v)) { v.meow(); }
}
