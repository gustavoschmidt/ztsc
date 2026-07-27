// The negative direction of 019/020: a member whose own annotation indexes at
// itself is genuinely circular, and the lazy single-member lookup must not
// chase it. tsc reports TS2502; ztsc cuts the recursion and stays silent (a
// registered under-report — see DEFERRED). What this case pins is that the cut
// still happens: the file has to terminate rather than recur forever.
class A {
  a: A["a"] = null as any;
}

class B {
  x: B["y"] = null as any;
  y: B["x"] = null as any;
}

// A self-index that is NOT circular still resolves.
class D {
  n: number = 1;
  m: D["n"] = 2;
}

declare const d: D;
const dok: number = d.m;
const dbad: string = d.m; // TS2322

declare const a: A;
declare const b: B;
const keepA = a;
const keepB = b;
