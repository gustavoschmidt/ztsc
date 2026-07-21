import type { DPath } from "./lib";

type F = { weight: number; nested: { deep: string } };

const ok1: DPath<F> = "weight"; // ok
const ok2: DPath<F> = "nested"; // ok
const ok3: DPath<F> = "nested.deep"; // ok — the reduced cross-module dotted path
const bad: DPath<F> = "nope"; // TS2322 — not a member of the field-name union
export {};
