import type { Elem } from "./lib";

type R = Elem<number[]>;

const ok: R = { v: 42 }; // ok — V bound to number
const bad: R = { v: "x" }; // TS2322 — V is number, not string
export {};
