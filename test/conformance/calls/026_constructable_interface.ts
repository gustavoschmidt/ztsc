interface Ctor {
  new (n: number): { value: number };
  readonly tag: string;
}
declare const K: Ctor;
const obj = new K(3);
const v: number = obj.value;
const t: string = K.tag;
const bad = new K("no");
