class Conv {
  to(x: string): number;
  to(x: number): string;
  to(x: string | number): string | number { return typeof x === "string" ? 0 : "s"; }
}
const c = new Conv();
const n: number = c.to("a");
const s: string = c.to(1);
