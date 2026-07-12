interface Circle { kind: "circle"; radius: number; }
interface Square { kind: "square"; side: number; }
type Shape = Circle | Square;
function area(s: Shape): number {
  if (s.kind === "circle") { return s.radius * s.radius; }
  return s.side * s.side;
}
