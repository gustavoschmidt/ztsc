class Point {
  x: number;
  y: number = 0;
  constructor(x: number) { this.x = x; }
}
const p = new Point(1);
const n: number = p.x;
