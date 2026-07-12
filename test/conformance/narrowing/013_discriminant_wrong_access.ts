interface Circle { kind: "circle"; radius: number; }
interface Square { kind: "square"; side: number; }
type Shape = Circle | Square;
function f(s: Shape): number {
  if (s.kind === "circle") { return s.side; }
  return 0;
}
