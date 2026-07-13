namespace N {
  export interface Point {
    x: number;
    y: number;
  }
  export type Pair = Point;
}

const p: N.Point = { x: 1, y: 2 };
const q: N.Pair = { x: 3, y: 4 };
