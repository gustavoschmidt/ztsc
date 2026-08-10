export class Emitter<T = unknown> {
  tag?: T;
  release(): void {}
}

export interface Shape {
  n: number;
}
