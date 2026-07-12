import type { Shape } from "./shapes";
function area(s: Shape): number {
  if (s.kind === "circle") return s.radius * 3;
  return s.side * s.side;
}
const a: number = area({ kind: "circle", radius: 2 });
