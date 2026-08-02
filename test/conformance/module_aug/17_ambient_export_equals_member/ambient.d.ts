// `import("m").member` where `m` is `export = <namespace>`: the member lives on
// the export-assigned entity, not in the module's own export table (which holds
// only the assignment under a reserved key). The `node:`-prefixed alias adds one
// more hop — `declare module "node:assert" { import a = require("assert");
// export = a; }` — so the lookup has to follow an ambient-to-ambient `export =`
// chain. Every `typeof import("node:assert").<fn>` in `@types/node`'s
// `test.d.ts` is this shape.
declare module "asserts" {
  function asserts(v: unknown): void;
  namespace asserts {
    function ok(v: unknown): void;
    function equal(a: unknown, b: unknown): void;
    interface Options {
      strict: boolean;
    }
  }
  export = asserts;
}

declare module "node:asserts" {
  import a = require("asserts");
  export = a;
}
