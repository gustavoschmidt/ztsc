interface ArrayCtor {
  new <T>(len: number): T[];
  <T>(len: number): T[];
  readonly prototype: unknown;
  isThing(x: unknown): boolean;
}
declare const Arr: ArrayCtor;
const a: string[] = new Arr<string>(3);
const b: number[] = Arr<number>(3);
const p = Arr.prototype;
const c: boolean = Arr.isThing(1);
const bad: number[] = new Arr<string>(3);
