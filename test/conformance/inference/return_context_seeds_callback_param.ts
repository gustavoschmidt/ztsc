// tsc's ReturnType-priority inference pass runs before any argument is
// contextually typed, so a type parameter reachable only through a CALLBACK
// PARAMETER is fixed from the contextual return type and the callback's own
// parameter is typed with it.

// The shape that motivates it: `new Promise<T>(executor: (resolve: (value:
// T | PromiseLike<T>) => void, …) => void)` under a contextual `Promise<void>`.
// `resolve()` with no argument is legal only once `resolve`'s parameter IS
// `void`.
export function a(): Promise<void> {
  return new Promise((resolve) => {
    resolve();
  });
}

// …including from a nested closure.
export function b(): Promise<void> {
  return new Promise((resolve) => {
    const inner = () => {
      resolve();
    };
    inner();
  });
}

export function c(): Promise<void> {
  return new Promise((resolve, reject) => {
    void reject;
    resolve();
  });
}

// A non-void payload is checked against the seeded parameter type.
export function d(): Promise<number> {
  return new Promise((resolve) => {
    resolve(1);
  });
}

// A bare callback parameter seeds the same way.
declare function g<T>(cb: (value: T) => void): T[];
export const e: string[] = g((value) => {
  const s: string = value;
  void s;
});

// A callback RETURN keeps the seeding it already had.
declare function h<U>(cb: () => U): U[];
export const f: string[] = h(() => "x");

// A type parameter buried in a union callback return is still left to the
// ordinary post-argument inference.
declare function k<U>(cb: (n: number) => U | readonly U[]): U[];
export const l: string[] = k((n) => (n > 1 ? ["a"] : []));
