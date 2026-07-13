// A get-only accessor is a read-only property: writing to it is TS2540.
class C {
  get x(): number { return 1; }
}
const c = new C();
const n: number = c.x;
c.x = 5;
