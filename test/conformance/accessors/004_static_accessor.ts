// A static get-only accessor is a read-only static property.
class C {
  static get x(): number { return 1; }
}
const n: number = C.x;
C.x = 5;
