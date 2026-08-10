// The negative half of 038: de-freshening an array element must not make the
// element type WIDER or NARROWER than tsc's, only non-fresh.
declare function mk<U extends string, T extends Readonly<[U, ...U[]]>>(
  values: T,
): {out: T[number]};

const e = mk(['system', 'light', 'dark']);
type Mode = (typeof e)['out'];

declare const raw: Mode;

// Still a literal union, so a non-member is still rejected.
export const a: Mode = 'nope';

// Still not `string`.
declare const s: string;
export const b: Mode = s;

// A plain array literal's element type is the widened union, so a tuple read
// of it is not a literal.
const plain = ['system', 'light'];
export const c: 'system' = plain[0];

// A `const` assertion keeps the tuple and its literals.
const frozen = ['system', 'light'] as const;
export const d: 'system' = frozen[0];
export const f: 'light' = frozen[0];
