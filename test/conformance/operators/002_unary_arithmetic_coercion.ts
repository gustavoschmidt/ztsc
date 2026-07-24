// Unary `+`, `-`, `~` are coercion operators: tsc accepts ANY operand and
// returns `number` (never TS2356). Only `++`/`--` (and binary arithmetic)
// require an arithmetic operand. Emitting TS2356 for `+v` where
// `v: string | number` (e.g. `.map((v: string | number) => +v)`) was a false
// positive.
declare const s: string;
declare const sn: string | number;
declare const o: {};

// accepted — no TS2356
const a: number = +s;
const b: number = -s;
const c: number = ~s;
const d: number = +sn;
const e: number = -sn;
const f: number = ~sn;
const g: number = +o;

// `++`/`--` on a non-arithmetic operand still errors TS2356.
function bump(str: string): void {
  str++;
  --str;
}
