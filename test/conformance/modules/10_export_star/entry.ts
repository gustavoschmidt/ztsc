import { add, mul, Point } from "./barrel";
const p: Point = { x: 1, y: 2 };
const n: number = add(mul(2, 3), p.x);
