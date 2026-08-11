// DEFAULT `resolvePackageJsonExports` (true): a package.json `exports` map is
// authoritative, so a map with no `types` condition HIDES the package's own
// top-level `"types"` key. `hidden-types` publishes both; resolution lands on
// the JavaScript the map names, the module is untyped (`any`), and the specifier
// gets TS7016 under noImplicitAny.
//
// The pair of this case is 74_pkg_exports_off, which is the same package with
// `resolvePackageJsonExports: false` — there the declarations win and this file
// would be clean. Keeping both pins the option in BOTH directions.
import { thing } from "hidden-types";

// `thing` is `any` here, so nothing about its shape is asserted (an operation
// that only makes sense on the real declaration type would report in the
// exports-off case and not here — that asymmetry is 74's job, not this one).
export const v: unknown = thing;
