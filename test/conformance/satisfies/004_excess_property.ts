// The excess-property check still runs for `satisfies`: TS2353.
interface Point { x: number; y: number; }
const p = { x: 1, y: 2, z: 3 } satisfies Point;
