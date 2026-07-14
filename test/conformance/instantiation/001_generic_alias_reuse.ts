// M15: one generic body instantiated many distinct ways, plus repeated
// instantiations of the same (target, type-args) — exercises the
// instantiation cache and canonical-map interning. All uses are well-typed,
// so tsc reports nothing (no .expected file).
type Box<T> = { value: T };
type Pair<A, B> = { first: A; second: B };
type Wrap<T> = Box<Box<T>>;

const a: Box<number> = { value: 1 };
const b: Box<string> = { value: "x" };
const c: Box<number> = { value: 2 }; // same instantiation as `a`
const p: Pair<number, string> = { first: 1, second: "x" };
const q: Pair<string, number> = { first: "x", second: 1 };
const w: Wrap<number> = { value: { value: 3 } };

function id<T>(x: T): T {
  return x;
}
function pair<A, B>(x: A, y: B): Pair<A, B> {
  return { first: x, second: y };
}

const n: number = id(1);
const s: string = id("hi");
const bn: Box<number> = id<Box<number>>({ value: 5 });
const pp: Pair<number, string> = pair(1, "x");
const qq: Pair<boolean, boolean> = pair(true, false);

// Read the reused instantiations back through their members.
const av: number = a.value;
const cv: number = c.value;
const pf: number = p.first;
const wv: number = w.value.value;
