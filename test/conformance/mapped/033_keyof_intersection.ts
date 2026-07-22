// `keyof (A & B) === keyof A | keyof B` (tsc's `getIndexType` maps over the
// intersection constituents and unions their key sets). A concrete param-free
// intersection must not collapse `keyof` to `never`, or a conditional
// `K extends keyof (A & B)` wrongly takes its false arm.
type A = { a: number };
type B = { b: string };
type K = keyof (A & B);

// Non-vacuous: `never` is assignable to everything, so a `keyof -> value`
// assignment would be a vacuous control. Assign INTO the keyof instead — only a
// real `'a' | 'b'` union rejects `'c'`.
const k1: K = 'a';
const k2: K = 'b';
const bad: K = 'c'; // TS2322 — proves K is 'a'|'b', not never/string

// The conditional-extends use (react-hook-form PathValue/FieldPath over an
// intersection form type): `'a' extends keyof (A & B)` must be TRUE, so the
// indexed value is recovered rather than collapsing to `never`.
type Get<T, P> = P extends keyof T ? T[P] : never;
type Va = Get<A & B, 'a'>;
const va: Va = 1;
const vaBad: Va = 'x'; // TS2322 — proves Va is number, not never
