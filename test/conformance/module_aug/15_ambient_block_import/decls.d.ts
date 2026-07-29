// The shape an app's `global.d.ts` uses to describe a dependency that ships no
// types of its own: an ambient `declare module` block whose body IMPORTS the
// types it builds on.
declare module "untypedlib" {
  import type { ResizeOptions, Engine } from "typedlib";
  namespace Wrap {
    interface Opts extends ResizeOptions {
      max: number;
    }
    interface Inst {
      reduce(o: Opts): string;
      engine(): Engine;
    }
    interface Static {
      (o?: number): Inst;
    }
  }
  const wrap: Wrap.Static;
  export = wrap;
}
