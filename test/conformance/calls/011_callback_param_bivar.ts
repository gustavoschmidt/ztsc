declare function each(xs: number[], cb: (x: number, i: number) => void): void;
each([1, 2], (x) => {});
each([1, 2], (x, i) => {});
