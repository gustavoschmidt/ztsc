// A NAMED re-export of a name its target module only has through that target's
// own `export * from "<ambient module>"`. The re-export is resolved against a
// table that is still growing when the re-exporting file's own table is built,
// so both the lookup and the "no exported member" diagnostic have to wait for
// the merge — otherwise this line is TS2305 while `import { starFn } from
// "starpkg2"` (entry.ts) resolves the very same name.
export { starFn as relayFn } from "starpkg2";
export type { StarIface as RelayIface } from "starpkg2";
export { ownFn as relayOwnFn } from "starpkg2";

// Negative control: waiting for the merge must not lose the diagnostic — a name
// no star can ever contribute is still TS2305.
export { notThere } from "starpkg2";
