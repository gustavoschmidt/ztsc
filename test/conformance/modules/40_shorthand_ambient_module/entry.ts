/// <reference path="./shims.d.ts" />
import css from "./styles.scss";
import { anything } from "./other.scss";
import plain from "virtual:plain";

// A shorthand ambient module's exports are `any`: neither line is an error.
const a: string = css.whatever;
const b: number = anything;
const c: string = plain;

// The interface declared *after* the shorthand shim still binds…
const ok: Marker = { m: 1 };
// …and is a real type, not `any`.
const bad: Marker = { m: "no" }; // TS2322

export { a, b, c, ok, bad };
