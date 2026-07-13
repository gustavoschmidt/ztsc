const nums: number[] = [3, 1, 2];
const found: number | undefined = nums.find((x) => x > 1);
const fidx: number = nums.findIndex((x, i) => x === 2 && i > 0);
const anyBig: boolean = nums.some((x) => x > 2);
const allPos: boolean = nums.every((x) => x > 0);
const sorted: number[] = nums.sort((a, b) => a - b);
const sortedDefault: number[] = nums.sort();
const filled: number[] = nums.fill(0);
