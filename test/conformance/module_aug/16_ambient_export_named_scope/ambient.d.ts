// `export { X }` inside a `declare module "spec" { … }` body names an entity in
// the BLOCK, not at file scope; a nested `namespace N { export { X }; }`
// re-exports a namespace member and is not a module export at all. Resolving
// both against the file scope reported TS2304 for every re-export in
// `@types/node` (`inspector.d.ts`, `fs.d.ts`, `test.d.ts`, `util.d.ts`, …).
declare module "insp" {
  class Session {
    connect(): void;
  }
  function open(port?: number): void;
  interface Note {
    method: string;
  }
  export { Session, open, Note };
}

declare module "promisesmod" {
  export function readFile(p: string): string;
}

declare module "fsish" {
  import * as promises from "promisesmod";
  export { promises };
}

declare module "testish" {
  function after(): void;
  function test(): void;
  namespace test {
    export { after };
  }
  export { test };
}
