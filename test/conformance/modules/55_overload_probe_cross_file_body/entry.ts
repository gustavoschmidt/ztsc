import { dep } from "./dep";

declare function pick(a: string): string;
declare function pick(a: number): number;

// Checking this argument under the FIRST candidate materializes `dep` — which
// walks `dep.ts`'s arrow body and files its diagnostic — and only then rejects
// on `string`. The rejection must withdraw what the candidate said about the
// argument, not the collateral it dragged in from another file.
export const r = pick(dep(1));
