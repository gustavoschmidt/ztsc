const words: string[] = ["a", "bb", "ccc"];
const lens: number[] = words.map((w) => w.length);
const strs: string[] = lens.map((n) => n.toFixed(0));
const flags: boolean[] = words.map((w) => w.includes("b"));
const upper: string[] = words.map((w) => w.toUpperCase());
const nested: number[] = [1, 2].map((x) => [x, x].length);
