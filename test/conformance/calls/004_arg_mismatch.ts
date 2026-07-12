function f(a: number): void {}
f("nope");
declare function g(cb: (x: number) => string): void;
g((x) => x + 1);
