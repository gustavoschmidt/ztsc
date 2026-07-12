interface A { a: number; }
interface B extends A { b: string; }
interface C extends B { c: boolean; }
declare const c: C;
const asA: A = c;
const asB: B = c;
declare const justA: A;
const bad: C = justA;
