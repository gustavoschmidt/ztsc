// A class merges with function declarations of the same name (tsc's
// `ClassExcludes` omits `Function` and `FunctionExcludes` omits `Class`), so a
// `.d.ts` can describe a constructor that also works without `new`. The merged
// symbol carries BOTH signature sets: call signatures from the functions,
// construct signatures + statics from the class. Shape taken from
// ua-parser-js, which declares `function UAParser(…): IResult` overloads next
// to `class UAParser` inside a namespace and then `export = UAParser`.

declare namespace NS {
  export function F(x?: string): { a: number };
  export function F(x?: number): { a: number };
  export class F {
    constructor(x?: string);
    a: number;
    static s: string;
  }
}

// Call side: the function overloads.
const c1: number = NS.F('x').a;
const c2: number = NS.F(1).a;
const cBad: string = NS.F('x').a; // TS2322
NS.F(true); // TS2345

// Construct side + statics: the class.
const n1: NS.F = new NS.F('y');
const n2: number = new NS.F().a;
const st: string = NS.F.s;
const stBad: number = NS.F.s; // TS2322

// Same merge at top level, both halves ambient.
declare function G(x: string): number;
declare function G(x: number): number;
declare class G {
  b: string;
}
const g1: number = G('s');
const g2: string = new G().b;
const g3: number = G(true); // TS2345

// The class half being ambient is what makes the merge legal: a function with
// a body may merge with it.
declare class H {
  h: number;
}
function H(x: string) {
  return x;
}
const h1: string = H('s');
const h2: number = new H().h;

// A NON-ambient class cannot: TS2813 on the class, TS2814 on every function
// declaration, in either declaration order.
class K {
  k = 1;
}
function K(x: string) {
  return x;
}

function L(x: string) {
  return x;
}
class L {
  l = 1;
}
