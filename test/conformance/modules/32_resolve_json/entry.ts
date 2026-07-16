// resolveJsonModule: the `*.json` import resolves (no TS2307). tsc synthesizes a
// structural type; ztsc types it opaquely as `any` (under-report). This case is
// written to type-check clean under both: property reads flow to `any`/their
// real type and land in `number`/`string` without error.
import data from "./data.json";
import * as ns from "./data.json";

const n: number = data.count;
const s: string = ns.name;
export const total: number = n + ns.count;
export const first: string = s;
