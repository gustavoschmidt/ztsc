import type { DPath } from "./lib";

type F = { weight: number; nested: { deep: string } };

const a: DPath<F> = "weight"; // ok
const b: DPath<F> = "nested"; // ok
const c: DPath<F> = "nested.deep"; // ok — reduced dotted path (branch taken is the object branch)
const d: DPath<F> = "nope"; // TS2322 — not a member of the field-name union
export {};
