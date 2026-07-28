// A package that publishes an `exports` map whose ROOT (".") entry resolves —
// to JavaScript, with no declaration twin beside it. The map is authoritative:
// tsc stops there and reports the module as untyped, even though the package
// also carries a top-level `"types"` key pointing at real declarations. The
// shape is `browser-fs-access@0.29`'s, verbatim.
//
// Falling through to that hidden `"types"` typed the callback below and made
// the whole file silent. The correct answer is TS7016 at each specifier plus
// the implicit-any cascade in the untyped callback.
import { fileOpen } from "fsaccess";
import type { Handle } from "fsaccess";

// The same diagnostic for a package that is simply JavaScript-only: its `main`
// is `.js` and it ships no declarations anywhere.
import { shout } from "plainjs";

export type H = Handle;
export const r = fileOpen({
  legacySetup: (resolve, input) => {
    void resolve;
    void input;
  },
});
export const s = shout("x");
