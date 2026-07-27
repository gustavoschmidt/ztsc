import type { Props } from "./types";
import type { Thing } from "./cls";

declare const p: Props;

// Both indexed accesses in the cycle-participating alias must resolve. Before
// the lazy single-member lookup only `a1` did; `a2` was `any`, so only the
// first of the four diagnostics below was reported.
const ok1: Thing = p.a1;
const ok2: (a: number) => string = p.a2;

const bad1: string = p.a1; // TS2322
const bad2: string = p.a2; // TS2322
const bad3: number = p.a2; // TS2322
const bad4: (a: string) => string = p.a2; // TS2322
