// A namespace's exports are its `export`ed MEMBERS. Module syntax written in
// its body is rejected by two halves of one rule
// (`checkExternalImportOrExportDeclaration`):
//
//   * TS1194 for an export declaration,
//   * TS1147 for an import that names a module,
//
// and a statement carrying a module SPECIFIER is blamed on the specifier.

namespace Live {
    export var V = 1;
    export interface I {}
    export { V as v };
    export type { I as i };
    export * from "./nowhere";
    export * as ns from "./nowhere";
    export { V as default };
    import * as N1 from "./nowhere";
    import N2 from "./nowhere";
    import { thing as N3 } from "./nowhere";
    export import N4 = require("./nowhere");
    import "./nowhere";
}

// An AMBIENT namespace still rejects anything naming a module, but its bare
// `export { … }` is the legal re-export idiom.
declare namespace Ambient {
    function _try(m: Function): any;
    export { _try as try };
    export * from "./nowhere";
    import * as A1 from "./nowhere";
    import A2 = require("./nowhere");
}

// A `declare module "spec"` block is an ambient MODULE, not a namespace, and
// takes module syntax. This file is deliberately a SCRIPT (no top-level export)
// so the block is an ambient declaration rather than an augmentation of a
// module that does not exist. Only the export half is exercised: an import
// naming a module inside one needs a resolvable specifier, which a single-file
// case has nowhere to put — the ts-suite covers it.
declare module "spec" {
    export var Y: number;
    export { Y as y };
}

// An entity-name alias names no module and is how a namespace aliases.
namespace Alias {
    export namespace Inner {
        export var z = 1;
    }
    import I = Inner;
    export var useI = I.z;
}
