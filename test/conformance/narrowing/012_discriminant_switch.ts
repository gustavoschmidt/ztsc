interface Circle { kind: "circle"; radius: number; }
interface Square { kind: "square"; side: number; }
interface Tri { kind: "tri"; base: number; height: number; }
type Shape = Circle | Square | Tri;
function area(s: Shape): number {
  switch (s.kind) {
    case "circle": return s.radius;
    case "square": return s.side;
    case "tri": return s.base * s.height;
  }
}
