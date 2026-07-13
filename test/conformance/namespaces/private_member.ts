namespace N {
  export const x = 1;
  const priv = 3;
}

const a: number = N.x;
const bad = N.priv;
