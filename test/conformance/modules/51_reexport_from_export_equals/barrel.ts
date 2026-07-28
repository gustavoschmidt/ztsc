// `export { X } from "m"` where `m` is `export = ns` reads the namespace
// member `ns.X` — the same rule `import { X } from "m"` follows. Both names
// below resolve; neither may raise TS2305.
export { value } from "eqlib";
export type { Opts } from "eqlib";

// `untyped-lib` is JavaScript-only: under `allowJs` ztsc loads it as the
// synthetic opaque body `declare const j: any; export = j;`. A re-export from
// such a module must degrade to `any`, not accuse the placeholder of a missing
// member.
export { helper } from "untyped-lib";
