declare namespace D {
  export const x: number;
  export interface I {
    n: number;
  }
}

const a: number = D.x;
const b: D.I = { n: 1 };
