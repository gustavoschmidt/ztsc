class Box<T> {
  value: T;
  constructor(v: T) { this.value = v; }
  get(): T { return this.value; }
}
const b = new Box<number>(1);
const n: number = b.get();
const c = new Box("s");
const s: string = c.get();
const bad: number = c.get();
