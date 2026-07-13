// A get/set pair is one property; its type is the getter's return type,
// and it is writable when a setter exists.
class C {
  get x(): number { return 1; }
  set x(v: number) {}
}
const c = new C();
const n: number = c.x;
c.x = 5;
