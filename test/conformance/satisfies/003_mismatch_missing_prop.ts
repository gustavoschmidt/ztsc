// A missing required property makes the operand not satisfy the target: TS1360.
interface Point { x: number; y: number; }
const p = { x: 1 } satisfies Point;
