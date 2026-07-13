namespace N {
  export const x = 1;
  export function f(): number {
    return x + 2;
  }
  const priv = 3;
  export const y: number = priv;
}

const a: number = N.x;
const b: number = N.f();
const c: number = N.y;
