// `export { X }` inside an ambient module body resolves `X` the way tsc does:
// the module's own locals first, then outward, then the globals — including
// the globals the SAME file contributes from its `global { … }` block. Real
// `@types/node` `buffer.d.ts` writes `declare module "buffer" { … global { var
// Buffer … } export { Buffer }; }`, and the nested `namespace NodeJS { export
// { BufferEncoding }; }` re-exports a name declared beside it in the block.
declare module "buf" {
  global {
    type BEnc = "utf8" | "hex";
    interface Buf {
      enc: BEnc;
      len: number;
    }
    var Buf: {
      new (n: number): Buf;
    };
    // A namespace-member re-export inside the block. ztsc does not model the
    // member ALIAS (`Enc.BEnc` stays unknown — an under-report), but it must
    // not report the re-export itself, which is what `@types/node`'s
    // `global { namespace NodeJS { export { BufferEncoding }; } }` needs.
    namespace Enc {
      export { BEnc };
    }
  }
  export { Buf };
}

declare module "consumer" {
  import { Buf } from "buf";
  export const b: Buf;
}

declare const g: Buf;
const e1: BEnc = g.enc;
const n: number = g.len;
const bad: number = g.enc;
