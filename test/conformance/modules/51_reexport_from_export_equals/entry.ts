import { value, helper, type Opts } from "./barrel";

export const n: number = value; // ok — the re-export kept `number`
export const o: Opts = { a: "x" }; // ok — the re-exported interface
export const anything: string = helper; // ok — degraded to `any`

export const bad: string = value; // TS2322 — proves `value` is not `any`
export const badOpts: Opts = { a: 1 }; // TS2322 — proves `Opts` is not `any`
