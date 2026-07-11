# Conformance suite

Differential test cases for the ztsc checker, validated against `tsc`
(PLAN.md §3). Currently empty — cases start landing with the checker (M4).

## Case format

Each case is a pair of files in this directory:

- `<name>.ts` — a TypeScript source file restricted to the ztsc v0.0.1
  subset (PLAN.md §5).
- `<name>.expected` — the expected-diagnostics snapshot: one diagnostic per
  line in the form

  ```
  <code> <start>..<end> <message>
  ```

  where `<code>` is the tsc-compatible error code (e.g. `TS2322`),
  `<start>..<end>` is the byte span in the `.ts` file, and `<message>` is the
  rendered message. An empty (or absent) `.expected` file means the case must
  produce no diagnostics.

## Runner

`test/run_conformance.zig` (wired into `zig build test`) discovers every
`.ts` file here, checks it with ztsc, and diffs the produced diagnostics
(code + span) against the snapshot. Snapshots are validated against real
`tsc` output when curated.

In M0 there is no checker yet, so the runner requires **zero** cases and any
`.ts` file added here fails the suite loudly rather than being skipped
silently.
