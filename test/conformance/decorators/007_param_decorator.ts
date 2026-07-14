// Parameter decorators are a grammar error under TC39 standard decorators
// (TS1206). The decorated parameter still binds normally (no cascade), so no
// TS2304/TS2554 follow.
declare const dec: any;
class A {
  method(@dec x: number): number { return x; }
  constructor(@dec y: string) {}
  two(@dec a: number, @dec b: string): void {}
}
function f(@dec z: number): number { return z; }
