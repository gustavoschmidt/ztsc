// A generic class whose type-parameter constraint (`Base`) is declared in
// THIS file. When `entry.ts` does `new Box(...)` without explicit type args,
// the checker infers the class type args and must evaluate the constraint
// node — an AST node id belonging to *this* file. Padding declarations push
// that constraint node's id high so it lands out of bounds of the smaller
// `entry.ts` tree, which used to panic (index out of bounds) before the
// constraint was resolved in its declaring file's context.
export interface Base {
  id: number;
  name: string;
}

export type Pad1 = { a: number; b: string; c: boolean; d: number };
export type Pad2 = { a: number; b: string; c: boolean; d: number };
export type Pad3 = { a: number; b: string; c: boolean; d: number };
export type Pad4 = { a: number; b: string; c: boolean; d: number };
export type Pad5 = { a: number; b: string; c: boolean; d: number };
export type Pad6 = { a: number; b: string; c: boolean; d: number };
export type Pad7 = { a: number; b: string; c: boolean; d: number };
export type Pad8 = { a: number; b: string; c: boolean; d: number };

export class Box<T extends Base> {
  value: T;
  constructor(v: T) {
    this.value = v;
  }
  get(): T {
    return this.value;
  }
}
