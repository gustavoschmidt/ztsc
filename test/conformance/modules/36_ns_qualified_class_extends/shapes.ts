export class Base<T> {
  value!: T;
  wrap(x: T): T { return x; }
}
export interface Named { name: string; }
