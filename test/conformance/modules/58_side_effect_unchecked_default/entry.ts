// `noUncheckedSideEffectImports` is OFF by default (tsc 5.6+ default, and the
// value this suite pins the oracle to). A side-effect-only `import "m"` whose
// specifier resolves to nothing is therefore accepted silently — bundler
// plugins own such specifiers (a CSS-only npm package is the common case).
// A *named* import of the same missing specifier is still TS2307, and the
// side-effect import of a module that does resolve still links it.
import "./missing-side-effect";
import "css-only-package-owned-by-the-bundler";
import "./present";
import { gone } from "./missing-named";

export const used: unknown = gone;
