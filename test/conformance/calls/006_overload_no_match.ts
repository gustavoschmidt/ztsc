function pick(x: string): string;
function pick(x: number): number;
function pick(x: string | number): string | number { return x; }
pick(true);
