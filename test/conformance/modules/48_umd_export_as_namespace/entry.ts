// `export as namespace Lib;` in a `export = Lib` package publishes the
// module's exported entity under the GLOBAL name `Lib`. A file that never
// imports the package can still write `Lib.Options` in type position — that is
// the whole point of a UMD declaration, and it is how @types/react's
// `React.CSSProperties` resolves in a file with no React import. ztsc parsed
// and discarded the declaration, so every such annotation degraded to `any`.
//
// This entry is what pulls the package into the program; `other.ts` is the
// file that uses the global.
import * as Direct from "umdlib";
import { viaGlobal, viaGlobalBad, mode } from "./other";

export const direct: Direct.Options = { width: 1 };
export const directBad: Direct.Options = { width: "x" };

export const w: number = viaGlobal.width;
export const wBad: string = viaGlobal.width;
export const v = viaGlobalBad;
export const m: "fast" | "slow" = mode;
