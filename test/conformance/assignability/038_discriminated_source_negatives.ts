// The discriminated-source rule requires EVERY discriminant value to be
// covered, and every matched constituent's other properties to be satisfied.
declare const k: "a" | "b";
declare const kd: "a" | "d";

type T = { type: "a"; x: number } | { type: "b"; x: number } | { type: "c"; y: string };
declare function take(t: T): void;

// "d" is covered by no constituent.
take({ type: kd, x: 1 });

// The payload is wrong for the "b" constituent (both want `x: number`).
take({ type: k, x: "s" });

// A constituent matched by the source needs its own required property.
type U = { type: "a"; x: number } | { type: "b"; x: number; extra: string };
declare function takeU(u: U): void;
takeU({ type: k, x: 1 });

// An excess property is still an excess property.
export const v: T = { type: k, x: 1, nope: true };

// A non-discriminant property does not license the rule: `tag` is `string` on
// both constituents, so nothing splits and the source must fit one whole.
type V = { tag: string; x: number } | { tag: string; y: string };
declare function takeV(v: V): void;
declare const bad: { tag: string; x: string };
takeV(bad);
