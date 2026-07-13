namespace N {
  interface Priv {
    n: number;
  }
  export const x = 1;
}

type T = N.Priv;
const v: T = { n: 1 };
