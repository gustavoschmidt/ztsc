// Why TS2578 ("Unused '@ts-expect-error' directive") stays unimplemented —
// written as a GATE rather than as prose in DEFERRED.
//
// TS2578 is only sound on a checker that reports everything the oracle does:
// it fires precisely when a directive suppressed nothing. Every deliberate
// under-report in `test/conformance/DEFERRED` is therefore a line where the
// oracle considers the directive USED and ztsc would consider it unused — so
// a TS2578 built on ztsc's own report set is a false positive on correct
// code, the one thing project policy forbids.
//
// Both directives below sit over a diagnostic ztsc deliberately does not
// make. The oracle reports nothing here (each directive is used), and ztsc
// reports nothing (it has no TS2578 to report), so the snapshot is empty and
// the two agree. Implement TS2578 without first closing these under-reports
// and this case fails with a `+TS2578` — which is the point.
export {};

// A NUMBER-literal key that names no member: oracle TS7053, ztsc silent
// (constassert/006 in DEFERRED).
const BITS = { 1: 8, 2: 16, 4: 32 } as const;
// @ts-expect-error
export const missing = BITS[3];

// A cast through a DEFERRED indexed access: oracle TS2352, ztsc silent
// (indexed/032 in DEFERRED).
export function k<T extends Record<keyof T, number>, K extends keyof T>(v: T[K]) {
  // @ts-expect-error
  return v as string;
}
