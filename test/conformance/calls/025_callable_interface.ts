interface Greeter {
  (name: string): string;
  greeting: string;
}
declare const g: Greeter;
const a: string = g("hi");
const b: string = g.greeting;
const c: number = g("x");
