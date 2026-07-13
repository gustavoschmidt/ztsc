// `satisfies` validates the operand against the target and the operand stays
// usable with its own type. Here the shape matches exactly, so it is clean and
// the properties are accessible.
interface Point { x: number; y: number; }
const p = { x: 1, y: 2 } satisfies Point;
const total: number = p.x + p.y;
