namespace N {
  export interface I {
    n: number;
  }
}

type T = N.Missing;
const v: T = 0;
