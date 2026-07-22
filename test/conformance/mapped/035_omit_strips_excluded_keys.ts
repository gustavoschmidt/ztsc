// Omit<T, K> = Pick<T, Exclude<keyof T, K>>. The distributive Exclude,
// composed inside the generic Omit alias (its check is `keyof X`, not a
// naked param), must still drop the excluded keys per-member. Regression:
// Omit resolved to the whole T, so the excluded key stayed required.
type T = { description?: string; id: string; count: number };
type O = Omit<T, 'id'>;

// 'id' is stripped: absent is fine, present is excess.
const a: O = { description: "x", count: 1 }; // ok
const b: O = { count: 1 }; // ok — description optional
const c: O = { id: "y", count: 1 }; // TS2353: id excess after strip

// Negative control: a NON-excluded required key stays required.
const d: O = { description: "x" }; // TS2741: count still required

// Multi-key omit + the reduced key union is exactly "count".
type Ex = Exclude<keyof T, 'id' | 'description'>;
const e: Ex = "count"; // ok
const f: Ex = "id"; // TS2322: "id" was excluded
