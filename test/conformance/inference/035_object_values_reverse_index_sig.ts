// `Object.values`/`Object.entries` infer their element type `T` from the union
// parameter `{ [s: string]: T } | ArrayLike<T>`. When the argument is a
// named-property object (or an enum object) with no index signature, `T` must
// be inferred from the source's OWN property types (tsc's inferFromIndexTypes) —
// otherwise `T` stays unbound and the result collapses to `unknown[]`, so any
// member access on the element is a spurious TS2339.
//
// The only intended errors below are the two that probe the inference is
// CONCRETE (not `any`): a property that genuinely does not exist on the inferred
// element type.

const vals = Object.values({ a: { s: 1 }, b: { s: 2 } });
vals.map((v) => v.s); // ok — v: { s: number }
vals.map((v) => v.nope); // TS2339 — proves v is concrete { s: number }, not any

// Explicit index-signature source keeps working.
const rec: { [k: string]: { s: number } } = { a: { s: 1 } };
Object.values(rec).map((v) => v.s); // ok

// Record<string, …> source keeps working.
const rec2: Record<string, { s: number }> = { a: { s: 1 } };
Object.values(rec2).map((v) => v.s); // ok

// Enum object: values() yields the enum member type.
enum Status {
  Active = "active",
  Closed = "closed",
}
const sv = Object.values(Status);
sv.map((s) => s.toUpperCase()); // ok — string enum members
sv.map((s) => s.nope); // TS2339 — proves s is concrete Status, not any
