// Which unresolved specifier earns WHICH diagnostic is decided by the import
// CLAUSE, not by how many names the clause binds.
//
//   * `import "m"` has no clause at all — a side-effect import, TS2882;
//   * `import {} from "m"` has an empty one, and is an ordinary named import
//     like any other — TS2307;
//   * `export {} from "m"` re-exports nothing, so tsc never resolves the
//     specifier and says nothing at all.

import "./missing-side-effect";

import {} from "./missing-empty-clause";
import { thing } from "./missing-named";
import def from "./missing-default";
import * as ns from "./missing-namespace";
import type {} from "./missing-type-only";

export {} from "./missing-empty-export";
export { other } from "./missing-named-export";
export * from "./missing-star-export";

// The resolved ones stay quiet in every shape.
import "./present";
import {} from "./present";
import { real } from "./present";
export {} from "./present";

const use = [thing, def, ns, real];
export { use };
