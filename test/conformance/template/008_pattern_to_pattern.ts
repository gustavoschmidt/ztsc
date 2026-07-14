// Template-pattern -> template-pattern assignability. ztsc has no
// pattern<->pattern matcher; it must not *reject* valid pattern assignments
// (M17.4: was a spurious TS2322 false positive). A concrete literal against a
// pattern still checks precisely, and a non-matching literal still errors.
declare const a: `a${string}`;
const w: `${string}` = a;              // ok — source pattern narrower than string
declare const h: `hi-${string}`;
const x: `${string}-${string}` = h;    // ok — pattern to pattern (lenient accept)
const lit: `id-${number}` = "id-42";   // ok — literal matches pattern
const bad: `id-${number}` = "id-xy";   // TS2322 — literal does not match pattern
