// A class member signature that mentions an alias which indexes back into the
// class. Because `use` has no return annotation its body is walked to infer
// one, and that walk materializes `Props` while the class's own instance type
// is still in progress — so every `C["k"]` in `Props` has to be answered from
// the single member rather than from the whole (unavailable) member table.
//
// Before the lazy member lookup, the FIRST access resolved and every later one
// collapsed to `any`, and the collapsed value was memoized into the alias for
// the rest of the run. Which access came first moved with traversal order, so
// the same program reported different diagnostics at different checker counts.
class Thing {
  z: number = 1;
}

type Props = {
  direct: number;
  a1: C["prop"];
  a2: C["method"];
  a3: C["arrow"];
  a4: C["opt"];
};

class C {
  prop: Thing = new Thing();
  method(a: number): string {
    return "";
  }
  arrow = (a: number): string => "";
  opt?: number;
  // No return annotation: inferring it is what closes the cycle.
  use(p: Props) {
    return p.direct;
  }
}

declare const p: Props;

const ok1: Thing = p.a1;
const ok2: (a: number) => string = p.a2;
const ok3: (a: number) => string = p.a3;
const ok4: number | undefined = p.a4;

const bad1: string = p.a1; // TS2322
const bad2: string = p.a2; // TS2322
const bad3: string = p.a3; // TS2322
const bad4: number = p.a4; // TS2322 (an optional member adds `undefined`)
