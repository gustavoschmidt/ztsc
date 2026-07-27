// @ts-nocheck
// The unresolvable import is a link diagnostic (TS2307) and is suppressed
// along with everything else semantic in this file. The exported value still
// has its declared type, so `entry.ts` checks against it normally.
import { missing } from "./nowhere-at-all";

export const label: string = "ok";
export const broken: string = 1;
