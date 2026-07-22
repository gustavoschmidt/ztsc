// A source string index signature does NOT satisfy a required NAMED target
// property in the assignability relation (tsc TS2739) — even though it does for
// member access. So `Record<string, T>` (an object whose only members come from
// a `[k: string]` index) is not assignable to a type with required named props.
type Named = { x: number; y: number };
declare const rec: Record<string, number>;
const bad1: Named = rec; // TS2739 — the index sig does not supply x, y

// Non-vacuous positive control: a source that actually HAS the named props is
// still assignable — the relation did not become blanket-strict, it only stopped
// letting a bare index signature stand in for a named property.
declare const named: { x: number; y: number; extra: boolean };
const ok: Named = named;

// Member ACCESS still reads through the index signature (unchanged): the change
// is scoped to the assignability relation, not property lookup.
const v: number = rec['anything'];
