// Polymorphic `this` also applies to interface methods: `next(): this` keeps
// the concrete interface type across a chain, and a member missing on that
// type still errors (TS2339).
interface Chain {
  next(): this;
  value: number;
}
declare const c: Chain;
const v: number = c.next().next().value;
c.next().bogus();
