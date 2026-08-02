// A class and a same-named interface merge into one declaration: the
// interface's own members AND its `extends` bases become part of the class's
// instance type, whichever block is written first.
interface Wrap {
  getSQL(): number;
}

// interface half FIRST.
interface Table extends Wrap {
  extra(): string;
}
declare class Table {
  readonly n: number;
}
declare const t: Table;
const t1: number = t.getSQL();
const t2: string = t.extra();
const t3: number = t.n;
const t4: string = t.n;

// class half FIRST.
declare class Four {
  readonly r: number;
}
interface Four extends Wrap {
  m4(): number;
}
declare const f: Four;
const f1: number = f.getSQL();
const f2: number = f.m4();
const f3: number = f.r;
const f4: string = f.getSQL();

// No interface half: the members really are absent.
declare class Bare {
  readonly b: number;
}
declare const bare: Bare;
const b1: number = bare.getSQL();
