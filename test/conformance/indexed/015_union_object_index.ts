// Indexed access distributes over a UNION OBJECT: (A | B)[K] === A[K] | B[K].
// Regression: `(typeof arr)[number]['key']` on a const tuple of object literals
// must yield the literal-key union, not `unknown`.
const DEFS = [
  { key: 'a', min: 1 },
  { key: 'b', min: 2 },
] as const;
type K = (typeof DEFS)[number]['key']; // 'a' | 'b'
const k1: K = 'a';
const k2: K = 'b';
const kbad: K = 'zzz'; // TS2322

// keyof over an intersection with Record<literal-union, V> keeps the Record keys.
type State = { x: number } & Record<K, { min: number }>;
const sk1: keyof State = 'a';
const sk2: keyof State = 'x';
const skbad: keyof State = 'zzz'; // TS2322

// Direct union-object indexed access.
type U = { key: 'a' } | { key: 'b' };
type UK = U['key']; // 'a' | 'b'
const ubad: UK = 'zzz'; // TS2322
