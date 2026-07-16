// `allowJs: true`: a bare specifier that resolves only to a JavaScript file (a
// package whose `main` is `.js` with no bundled/@types declarations) is typed
// opaquely as `any` instead of raising TS2307. ztsc never parses the JS body.
// The oracle (tsgo) is generated with `--allowJs --noImplicitAny false`, so it
// resolves the same `.js` entry and stays silent (no TS7016) — clean snapshot.
import * as legacy from "legacy-lib";

// `legacy` is `any` here (ztsc) / the inferred JS module shape (oracle); either
// way assigning it to `unknown` is valid, so no member access is asserted and
// the two agree.
export const v: unknown = legacy;
