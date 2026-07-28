export const value: number = 42;
export interface Shape {
  side: number;
}
export default function make(n: number): Shape {
  return { side: n };
}
