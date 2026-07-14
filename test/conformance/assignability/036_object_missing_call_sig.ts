interface Callable {
  (x: number): number;
  kind: string;
}
declare const obj: { kind: string };
const bad: Callable = obj;
declare const co: Callable;
const ok: { kind: string } = co;
