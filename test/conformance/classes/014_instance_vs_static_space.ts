class C {
  static make(): C { return new C(); }
  tag: string = "c";
}
const c: C = C.make();
const s: string = c.tag;
const bad = c.make;
