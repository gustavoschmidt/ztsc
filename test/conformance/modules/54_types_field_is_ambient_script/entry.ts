// Resolving `"types"` finds a file that declares no module of its own, so the
// specifier was "known" while the resolved file supplied nothing — the import
// fell through to a synthesized default and typed `any`, silencing everything
// below. An exactly-named ambient `declare module` beats a resolved SCRIPT.
import swatch from "swatch";

export const reds: string[] = swatch.red; // ok — the declared shape
export const bad: number = swatch.red; // TS2322 — proves it is not `any`
export const missing = swatch.green; // TS2339 — same
export const m = swatch.blue.map((c, i) => `${c}${i}`); // no TS7006 on c / i
