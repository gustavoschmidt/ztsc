// A set-only accessor is writable; its property type is the setter param.
class C {
  set x(v: number) {}
}
const c = new C();
c.x = 5;
