// A template-literal pattern (and a string-mapping intrinsic) is a SUBTYPE of
// `string`, and tsc reaches an object target through `getApparentType`, which
// hands it the same global `String` interface it hands `string`. So every
// target `string` satisfies, a pattern satisfies too.
//
// `{}` is the one that matters in practice: `csstype` spells an open-ended CSS
// value as `Globals | (string & {})`, and excalidraw's
// `` transform: `translate(${n}px, ${n}px)` `` has to reach it.

type Px = `${number}px`;
type Up = Uppercase<'a' | 'b'>;

declare const px: Px;
declare const up: Up;

const a: {} = px;
const b: string & {} = px;
const c: 'inherit' | 'initial' | (string & {}) = px;
const d: {} = up;
const e: { length: number } = px;
const f: string = px;

// Nothing new is accepted that `string` itself is not: an object-only target,
// and a property `String` does not have, still report.
const g: object = px; // TS2322
const h: { nope: number } = px; // TS2322
const i: number = px; // TS2322

export { a, b, c, d, e, f, g, h, i };
