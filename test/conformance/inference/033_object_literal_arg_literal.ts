// An object-literal argument is contextually typed by the parameter, so a
// property whose parameter type is a type variable constrained to a literal set
// keeps its fresh literal instead of widening to `string` — the type param then
// infers the literal. Gated to params that actually carry a literal-keeping
// type-variable property (a plain callback bag keeps its context-free check).
declare function pickName<T extends 'x' | 'y' | 'z'>(o: { name: T }): T;

// Positive: the literal is preserved, so `T` infers `'y'`.
const r1 = pickName({ name: 'y' });
const bad1: 'x' = r1; // TS2322 — proves r1 is 'y', not string

// Negative control: a fresh literal outside the constraint is kept AND checked,
// so it is rejected — not silently widened to an accepted `string`.
const r2 = pickName({ name: 'w' }); // TS2345
