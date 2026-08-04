// The seeded callback parameter is a real type, so what is passed to it is
// really checked.
export function a(): Promise<number> {
  return new Promise((resolve) => {
    resolve("x");
  });
}

declare function g<T>(cb: (value: T) => void): T[];
export const b: string[] = g((value) => {
  const n: number = value;
  void n;
});

// The seed is superseded by argument evidence, so a callback that really
// produces something else still reports against what it produced.
declare function h<U>(cb: () => U): U[];
export const c: string[] = h(() => 1);
