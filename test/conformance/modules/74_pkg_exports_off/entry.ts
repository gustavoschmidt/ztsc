// `resolvePackageJsonExports: false` — the package.json `exports` map is ignored
// entirely, so all three of the things a present map does stop happening:
//
//   1. it no longer resolves the specifier to the JavaScript it names,
//   2. it no longer HIDES the package's legacy top-level `"types"` key, and
//   3. it no longer blocks a subpath it does not name.
//
// The same package with the option at its default is 73_pkg_exports_hides_types,
// where the import is an untyped `any` (TS7016). Here it is fully typed — which
// this file asserts by making a mistake that only the REAL declarations catch:
// were the map still honored, `thing` would be `any` and both errors below would
// disappear, so a snapshot of two TS2322s is what pins the option on.
import { thing } from "hidden-types";
import { tag } from "hidden-types/lib/internal/util";

// `thing: { n: number }` (from index.d.ts, behind `"types"`).
export const bad: string = thing.n;

// `tag(): string` (from the un-exported subpath).
export const alsoBad: number = tag();

// The well-typed uses, so the case is not only about the errors.
export const good: number = thing.n;
export const alsoGood: string = tag();
