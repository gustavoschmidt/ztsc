import { Shape } from "./shapes";
export function area(s: Shape): number {
  if (s.kind === "circle") {
    return s.radius * s.radius * 3;
  }
  return s.side * s.side;
}
const bad: string = area({ kind: "square", side: 2 });
