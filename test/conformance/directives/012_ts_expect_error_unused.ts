// The oracle reports TS2578 ("Unused '@ts-expect-error' directive") when a
// directive suppresses nothing. ztsc implements the suppression but not the
// unused report: ztsc under-reports relative to the oracle, so a directive the
// oracle considers used can look unused here, and reporting on that basis would
// manufacture a false positive on correct code. Registered in DEFERRED as a
// deterministic under-report.
// @ts-expect-error
const a: string = "fine";
