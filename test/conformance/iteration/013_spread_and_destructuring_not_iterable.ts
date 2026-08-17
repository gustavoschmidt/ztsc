// TS2488 at the two sites that used to swallow a failed iteration protocol:
// an array-literal SPREAD operand, and the source of an array
// destructuring-ASSIGNMENT pattern (tsc's `checkArrayLiteralAssignment` reads
// the source's ITERATED type once for the whole pattern).

class OnlyNext {
  next() {
    return { value: 1, done: false };
  }
}

class SelfIteratorNoNext {
  [Symbol.iterator]() {
    return this;
  }
}

export const s1 = [...new OnlyNext()];
export const s2 = [...new SelfIteratorNoNext()];

let a: string, b: boolean;
let bs: boolean[];
[a, b] = { 0: "", 1: true };
[a, ...bs] = { 0: "", 1: true };

// NEGATIVE (must stay clean) -------------------------------------------------

class RealIterable {
  [Symbol.iterator]() {
    return [1, 2][Symbol.iterator]();
  }
}

export const ok1 = [...new RealIterable()];
export const ok2 = [...[1, 2, 3]];

let x: number, y: number, rest: number[];
[x, y] = [1, 2];
[x, ...rest] = [1, 2, 3];
