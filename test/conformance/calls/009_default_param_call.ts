function f(a: number, b = "x"): string { return b; }
const s: string = f(1);
f();
