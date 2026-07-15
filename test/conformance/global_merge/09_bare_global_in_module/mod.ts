// A script file (no top-level import/export): `declare module "mymod"` is an
// ambient module declaration, so its nested bare `global {}` block legally
// contributes to the global scope — the exact shape real `@types/node` uses
// (`declare module "buffer" { global { var Buffer … } }`).
declare module "mymod" {
  export function greet(): string;
  global {
    var GVAL: number;
    namespace G {
      interface Thing {
        x: number;
      }
    }
  }
}
