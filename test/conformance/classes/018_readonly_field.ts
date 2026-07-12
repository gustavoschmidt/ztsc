class C {
  readonly id: number = 1;
  bump(): void { }
}
const c = new C();
const n: number = c.id;
c.id = 2;
