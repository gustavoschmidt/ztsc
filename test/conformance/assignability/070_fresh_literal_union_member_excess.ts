// tsc's excess-property check is not a separate pass: it runs at the top of
// every relation query, so relating a FRESH object literal to a union re-runs
// it against EACH constituent. A constituent that does not know one of the
// literal's own properties therefore cannot satisfy the relation, even though
// asking the whole union ("does ANY constituent know this property?") is happy.
// The `crypto.subtle` algorithm parameter is the shape this comes from.

interface Alg {
  name: string;
}
interface Gcm extends Alg {
  iv: number;
  tagLength?: number;
}
type AlgId = Alg | string;

// `{ name, iv }` relates structurally to the bare `Alg` arm, but `iv` is
// unknown there; the only arm that knows `iv` rejects its type. So the whole
// relation fails and the error lands on `iv`.
declare function unionParam(a: AlgId | Gcm): void;
unionParam({ name: "AES-GCM", iv: "no" });

// Non-union control: same property, same error, no member selection involved.
declare function plainParam(a: Gcm): void;
plainParam({ name: "AES-GCM", iv: "no" });

// Union without the string arm.
declare function twoObjects(a: Alg | Gcm): void;
twoObjects({ name: "AES-GCM", iv: "no" });

// Plain assignment, not a call.
export const v1: AlgId | Gcm = { name: "AES-GCM", iv: "no" };

// --- accepted: some constituent knows every property AND relates -----------

unionParam({ name: "AES-GCM", iv: 12 });
export const v2: AlgId | Gcm = { name: "AES-GCM" };

// A constituent with an index signature knows everything.
declare function indexed(a: Alg | { [k: string]: unknown }): void;
indexed({ name: "AES-GCM", extra: 1 });

// A property unknown to EVERY constituent is the plain excess error, and it
// wins over the per-constituent walk.
declare function excess(a: Alg | Gcm): void;
excess({ name: "AES-GCM", nope: 1 });
