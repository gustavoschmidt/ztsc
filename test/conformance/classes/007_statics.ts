class Registry {
  static count: number = 0;
  static bump(): number { return Registry.count + 1; }
  id: number = 0;
}
const n: number = Registry.bump();
const bad = Registry.id;
