interface Fn {
  (x: number): number;
  (x: string): string;
}
declare const f: Fn;
const n: number = f(1);
const s: string = f("a");
const w: number = f(true);
