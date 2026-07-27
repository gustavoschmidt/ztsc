import { label } from "./other";

// `label` keeps its declared `string` type across the `@ts-nocheck` boundary,
// so this file's own diagnostics are unaffected.
const ok: string = label;
const bad: number = label;
export { ok, bad };
