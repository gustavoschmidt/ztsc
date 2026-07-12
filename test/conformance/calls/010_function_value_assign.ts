function inc(x: number): number { return x + 1; }
const f: (x: number) => number = inc;
const g: (x: string) => number = inc;
