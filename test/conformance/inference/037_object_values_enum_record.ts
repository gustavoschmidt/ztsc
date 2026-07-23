// An enum-keyed mapped type (`Record<E, V>` / `{ [P in E]: V }`) materializes
// with an index signature keyed by the enum's base (string for a string enum,
// number for a numeric one), so `Object.values`/`entries` recover the value
// type `V` — without it the map collapsed to `{}`, `T` stayed unbound, and the
// element read `unknown` (spurious TS2339). Symmetrically, an object literal
// built with computed enum-member keys (`{ [E.A]: v }`) stays assignable to the
// enum-keyed Record (no spurious TS2739 for "missing" enum keys).

enum Status {
  Draft = "draft",
  Sent = "sent",
}
type Info = { code: Status; label: string };

declare const byStatus: Record<Status, Info>;
Object.values(byStatus).map((v) => v.label); // ok — v: Info, not unknown
Object.values(byStatus).map((v) => v.absentXYZ); // TS2339 — proves v is concrete Info

// Explicit non-homomorphic mapped form over the same enum key.
type ByStatus = { [P in Status]: Info };
declare const m: ByStatus;
Object.values(m).map((v) => v.code); // ok

// Numeric enum key: values() still recovers the value type.
enum Dir {
  Up,
  Down,
}
declare const byDir: Record<Dir, Info>;
Object.values(byDir).map((v) => v.label); // ok

// Regression guard: a computed enum-member-keyed literal is assignable to the
// enum-keyed Record (must NOT raise TS2739 for the "missing" members).
const table: Record<Status, Info> = {
  [Status.Draft]: { code: Status.Draft, label: "d" },
  [Status.Sent]: { code: Status.Sent, label: "s" },
};
table; // referenced
