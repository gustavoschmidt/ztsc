class Point { x: number = 0; }
function dist(p: Point): number { return p.x; }
dist(new Point());
dist({ x: 1 });
