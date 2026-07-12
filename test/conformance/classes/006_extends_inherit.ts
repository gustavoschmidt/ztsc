class Base { a: number = 1; m(): string { return "b"; } }
class Derived extends Base { b: boolean = true; }
const d = new Derived();
const n: number = d.a;
const s: string = d.m();
const bb: boolean = d.b;
