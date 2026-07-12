interface Point { x: number; y: number; }
declare const wide: { x: number; y: number; z: string };
const p: Point = wide;
declare const narrow: { x: number };
const q: Point = narrow;
