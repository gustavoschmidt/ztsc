function pick(x: string): string;
function pick(x: number): number;
function pick(x: string | number): string | number { return x; }
const s: string = pick("a");
const n: number = pick(1);
