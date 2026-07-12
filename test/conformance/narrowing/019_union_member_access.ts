interface A { shared: number; onlyA: string; }
interface B { shared: number; onlyB: boolean; }
declare const u: A | B;
const n: number = u.shared;
const bad = u.onlyA;
