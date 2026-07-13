namespace A {
  export namespace B {
    export const c = 1;
    export interface I {
      n: number;
    }
  }
}

const x: number = A.B.c;
const y: A.B.I = { n: 2 };
