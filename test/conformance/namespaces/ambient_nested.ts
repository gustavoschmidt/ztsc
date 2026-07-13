declare namespace Outer {
  const p: number;
  namespace Inner {
    const q: string;
  }
}
const a: number = Outer.p;
const b: string = Outer.Inner.q;
const bad: number = Outer.Inner.q;
